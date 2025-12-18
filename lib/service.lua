local package = {}
if _REQUIREDNAME == nil then
	service = package
else
	_G[_REQUIREDNAME] = package
end
    
-- Import Section
local setmetatable = setmetatable
local ngx = ngx
local io = io
local string = string
local error = error
local pairs = pairs
local os = os
local yaml = require "yaml"
local cjson = require "cjson.safe"
local Cache = require "moko.cache".Cache
local Profiler = require "moko.profiler".Profiler
local rabbitmq = require "resty.rabbitmqstomp"
local uuid = require 'resty.jit-uuid'
    
-- Encapsulate package
setfenv(1, package)

-- Define Service Class
Service = {}

function Service:new(instance, name)
	instance = instance or {}
	setmetatable(instance, self)

	self.__index = self

	-- Check if name refers to a valid service
	serviceFile = io.open("/home/moko/project/conf/services.yaml")
	serviceDefinitions = string.gsub(serviceFile:read("*all"), "\n\n", "\n")
	services = yaml.eval(serviceDefinitions)["services"]

	if services[name] then
		instance.name = name
		instance.path = "/"..services[name].path
    instance.external = services[name].external
    instance.cache = Cache:new()
    instance.profiler = Profiler:new()

    instance.exchange = services[name].exchange
	else
		error({code=500, error="Requested service '"..name.."' does not exist."})
	end

	-- Seed UUID generator
	uuid.seed()

	return instance
end

--############################# REST-Based Model #################@

function Service:get(endpoint, args, headers)
  -- Create request signature
  local signature = ""
  signature = signature .. endpoint

  if args ~= nil then
    for key, value in pairs(args) do
      signature = signature .. key .. value
    end
  end

  if headers ~= nil then
    for header, value in pairs(headers) do
      signature = signature .. header .. value
    end
  end

  signature = ngx.encode_base64(signature)

  -- Check if request exists in cache
  if not self.cache:retrieve(signature) then
  	self.cache:insert(signature, self:request({
  		method=ngx.HTTP_GET,
  		endpoint=endpoint,
  		args=args,
  		headers=headers
  	}))
  end

  return self.cache:retrieve(signature)
end

function Service:post(endpoint, args, headers, payload)
	return self:request({
		method=ngx.HTTP_POST,
		endpoint=endpoint,
		args=args,
		headers=headers,
		body=payload
	})
end

function Service:put(endpoint, args, headers, payload)
	return self:request({
		method=ngx.HTTP_PUT,
		endpoint=endpoint,
		args=args,
		headers=headers,
		body=payload
	})
end

function Service:patch(endpoint, args, headers, payload)
  return self:request({
    method=ngx.HTTP_PATCH,
    endpoint=endpoint,
    args=args,
    headers=headers,
    body=payload
  })
end

function Service:delete(endpoint, args, headers)
	return self:request({
		method=ngx.HTTP_DELETE,
		endpoint=endpoint,
		args=args,
		headers=headers
	})
end

function Service:options(endpoint, headers)
	return self:request({
		method=ngx.HTTP_OPTIONS,
		endpoint=endpoint,
		headers=headers
	})
end

function Service:request(parameters)
	-- Set default parameters if argument is missing
	parameters = parameters or {}

  -- Clear all client request headers before an external proxy request
  if self.external then
    for header, value in pairs(ngx.req.get_headers()) do
      ngx.req.clear_header(header)
    end
  end

	-- Set subrequest headers
	for header, value in pairs(parameters.headers or {}) do
    ngx.req.set_header(header, value)
	end

	-- Make subrequest
	log = self.profiler:start(
		self.name,
		parameters.endpoint or "/",
		parameters.method or ngx.HTTP_GET
	)

	response = ngx.location.capture(
		self.path .. (parameters.endpoint or "/"),
		{
			args = parameters.args or nil,
			method = parameters.method or ngx.HTTP_GET,
			body = cjson.encode(parameters.body) or nil
		}
	)

	self.profiler:stop(log)

	-- Return subrequest response
	return {
		code = (response and response.status) or 0,
		header = (response and response.header) or {},
		body = (response and cjson.decode(response.body)) or {}
	}
end

--############################# Event-Based Model #################@

function Service:migrate()
	return self:publish({
		exchange="database",
		resource=self.name,
		action="migrate",
		message={}
	})
end

function Service:publish(parameters)
	parameters = parameters or {
		exchange="default",
		resource="resource",
		action="retrieve",
		message={}
	}

	-- Initialise RabbitMQ connection
	local rabbitmq_connection, initialisation_error = rabbitmq:new({
		username=os.getenv("STOMP_USERNAME"),
		password=os.getenv("STOMP_PASSWORD")
	})

	if not rabbitmq_connection then
		io.stderr:write("Failed to create RabbitMQ client: "..initialisation_error)

		error({
			code=ngx.HTTP_SERVICE_UNAVAILABLE,
			error="The server was unable to communicate with a required upstream service."
		})
	end

	-- Set RabbitMQ Connection Timeout
	rabbitmq_connection:set_timeout(10000)

	-- Connect to RabbitMQ over STOMP
	local connection_ok, connection_error = rabbitmq_connection:connect(
		os.getenv("STOMP_HOST"),
		os.getenv("STOMP_PORT")
	)

	if not connection_ok then
		io.stderr:write("Failed to connect to RabbitMQ: "..connection_error)

		error({
			code=ngx.HTTP_SERVICE_UNAVAILABLE,
			error="The server was unable to communicate with a required upstream service."
		})
	end

	-- Setup message response consumer
	local subscription_id = uuid.generate_v4()
	local response_queue = "gateway-"..subscription_id
	local subscription_ok, subscription_error = rabbitmq_connection:subscribe({
		id=subscription_id,
		destination="/queue/"..response_queue,
		persistent="false",
		['auto-delete']="true",
		["content-type"]="application/json"
	})

	if not subscription_ok then
		io.stderr:write("Failed to subscribe to RabbitMQ response queue: "..subscription_error)

		error({
			code=ngx.HTTP_SERVICE_UNAVAILABLE,
			error="The server was unable to communicate with a required upstream service."
		})
	end

	-- Publish message to RabbitMQ over STOMP
	local headers = {
		destination="/exchange/"..parameters.exchange.."/"..parameters.resource..
			(parameters.action and ("."..parameters.action) or ""),
		persistent="true",
		["content-type"]="application/json"
	}

	-- Generate correlation ID
	local correlation_id = uuid.generate_v4()
	parameters.message["reply_to"] = response_queue
	parameters.message["correlation_id"] = correlation_id

	cjson.encode_empty_table_as_object(true)
	local body = cjson.encode(parameters.message)
	cjson.encode_empty_table_as_object(false)

	local send_ok, send_error = rabbitmq_connection:send(
		body,
		headers
	)

	if not send_ok then
		io.stderr:write("Failed to publish RabbitMQ message: "..send_error)

		error({
			code=ngx.HTTP_SERVICE_UNAVAILABLE,
			error="The server was unable to communicate with a required upstream service."
		})
	end

	-- Wait for a response from the service
	local response = nil

	while not response and os.time() do
		data, receipt_error = rabbitmq_connection:receive()


		if not data then
			io.stderr:write("Failed to receive RabbitMQ message: "..receipt_error)

			error({
				code=ngx.HTTP_SERVICE_UNAVAILABLE,
				error="The server was unable to communicate with a required upstream service."
			})
		end

		-- Discard response if it doesn't match our correlation ID
		parsed_data = cjson.decode(data)

		if not parsed_data then
			io.stderr:write("Received RabbitMQ message is not valid JSON: "..data)

			error({
				code=ngx.HTTP_SERVICE_UNAVAILABLE,
				error="The server was unable to communicate with a required upstream service."
			})
		end

		if parsed_data["correlation_id"] == correlation_id then
			response = parsed_data
		end
	end

	-- Unsubscribe from response queue
	local unsubscription_ok, unsubscription_error = rabbitmq_connection:unsubscribe({
		id=subscription_id
	})

	if not unsubscription_ok then
		io.stderr:write("Failed to unsubscribe from RabbitMQ response queue: "..unsubscription_error)

		error({
			code=ngx.HTTP_SERVICE_UNAVAILABLE,
			error="The server was unable to communicate with a required upstream service."
		})
	end

	-- Close RabbitMQ connection
	local disconnection_ok, disconnection_error = rabbitmq_connection:close()

	if not disconnection_ok then
		io.stderr:write("Failed to close RabbitMQ connection: "..disconnection_error)
	end

	if response["processing_error"] ~= nil then
		io.stderr:write("The upstream service could not process our message because: "..response["processing_error"])

		error({
			code=ngx.HTTP_SERVICE_UNAVAILABLE,
			error="The server was unable to communicate with a required upstream service."
		})
	else
		return response
	end

end

return package