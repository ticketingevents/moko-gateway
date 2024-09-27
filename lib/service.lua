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
local yaml = require "yaml"
local cjson = require "cjson.safe"
local Cache = require "moko.cache".Cache
local Profiler = require "moko.profiler".Profiler
    
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
	else
		error({code=500, error="Requested service '"..name.."' does not exist."})
	end

	return instance
end

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

return package