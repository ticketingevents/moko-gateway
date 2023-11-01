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
		instance.path = "/"..services[name].path
	else
		error({code=500, error="Requested service '"..name.."' does not exist."})
	end

	return instance
end

function Service:get(endpoint, args, headers)
	return self:request({
		method=ngx.HTTP_GET,
		endpoint=endpoint,
		args=args,
		headers=headers
	})
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

  -- Clear all client request headers before the proxy request
  for header, value in pairs(ngx.req.get_headers()) do
    ngx.req.clear_header(header)
  end

	-- Set subrequest headers
	for header, value in pairs(parameters.headers or {}) do
    ngx.req.set_header(header, value)
	end

	-- Make subrequest
	response = ngx.location.capture(
		self.path .. (parameters.endpoint or "/"),
		{
			args = parameters.args or nil,
			method = parameters.method or ngx.HTTP_GET,
			body = cjson.encode(parameters.body) or nil
		}
	)

	-- Return subrequest response
	return {
		code = (response and response.status) or 0,
		header = (response and response.header) or {},
		body = (response and cjson.decode(response.body)) or {}
	}
end

return package