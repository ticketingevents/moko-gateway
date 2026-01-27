local package = {}
if _REQUIREDNAME == nil then
	task = package
else
	_G[_REQUIREDNAME] = package
end
    
-- Import Section
local setmetatable = setmetatable
local ngx = ngx
local os = os
local io = io
local error = error
local math = math
local tostring = tostring
local cjson = require "cjson.safe"
local rabbitmq = require "resty.rabbitmqstomp"
local Service = require "moko.service".Service
    
-- Encapsulate package
setfenv(1, package)

-- Define Task Class
Task = {}

function Task:new(instance)
	instance = instance or {}
	setmetatable(instance, self)
	self.__index = self

	instance.uri = ngx.var.uri
	return instance
end

function Task:buildService(name)
	return Service:new({}, name)
end

function Task:ok(payload)
	if ngx.req.get_method() == "POST" then
		return self:created(payload)
	else
		return self:respond(ngx.HTTP_OK, payload, "application/json")
	end
end

function Task:created(payload)
	return self:respond(ngx.HTTP_CREATED, payload, "application/json")
end

function Task:noContent()
	return self:respond(ngx.HTTP_NO_CONTENT, {}, "application/json")
end

function Task:bad(message)
	return self:fail(ngx.HTTP_BAD_REQUEST, message)
end

function Task:unauthorised(message)
	return self:fail(ngx.HTTP_UNAUTHORIZED, message)
end

function Task:paymentRequired(message)
	return self:fail(ngx.HTTP_PAYMENT_REQUIRED, message)
end

function Task:forbidden(message)
	return self:fail(ngx.HTTP_FORBIDDEN, message)
end

function Task:notFound(message)
	return self:fail(ngx.HTTP_NOT_FOUND, message)
end

function Task:notAllowed(message)
	return self:fail(ngx.HTTP_NOT_ALLOWED, message)
end

function Task:notAcceptable(message)
	return self:fail(ngx.HTTP_NOT_ACCEPTABLE, message)
end

function Task:requestTimeout(message)
	return self:fail(ngx.HTTP_REQUEST_TIMEOUT, message)
end

function Task:conflict(message)
	return self:fail(ngx.HTTP_CONFLICT, message)
end

function Task:gone(message)
	return self:fail(ngx.HTTP_GONE, message)
end

function Task:upgradeRequired(message)
	return self:fail(ngx.HTTP_UPGRADE_REQUIRED, message)
end

function Task:tooManyRequests(message)
	return self:fail(ngx.HTTP_TOO_MANY_REQUESTS, message)
end

function Task:respond(code, payload, format)
	return {code=code, response=payload, format=format}
end

function Task:fail(code, message)
	error({code=code, error=message})
end

function Task:rpc(procedure, arguments)
	parameters = {
		exchange=os.getenv("RPC_EXCHANGE"),
		procedure=procedure,
		arguments=arguments and arguments or {}
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
	rabbitmq_connection:set_timeout(30000)

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

	-- Seed random number
	math.randomseed(os.time() + os.clock())

	-- Setup message response consumer
	local subscription_id = tostring(math.random(1000000, 9999999))
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
		destination="/exchange/"..parameters.exchange.."/"..parameters.procedure,
		persistent="true",
		["content-type"]="application/json"
	}

	-- Generate correlation ID
	local correlation_id = tostring(math.random(1000000, 9999999))
	parameters.arguments["reply_to"] = response_queue
	parameters.arguments["correlation_id"] = correlation_id

	cjson.encode_empty_table_as_object(true)
	local body = cjson.encode(parameters.arguments)
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

	start = os.time()
	while not response and (os.time() - start) < 30 do
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

	return response

end

return package