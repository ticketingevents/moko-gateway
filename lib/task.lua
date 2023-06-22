local package = {}
if _REQUIREDNAME == nil then
	task = package
else
	_G[_REQUIREDNAME] = package
end
    
-- Import Section
local setmetatable = setmetatable
local ngx = ngx
local error = error
local Service = require "moko.service".Service
    
-- Encapsulate package
setfenv(1, package)

-- Define Task Class
Task = {}

function Task:new(instance)
	instance = instance or {}
	setmetatable(instance, self)
	self.__index = self
	return instance
end

function Task:buildService(name)
	return Service:new({}, name)
end

function Task:ok(payload)
	return self:respond(ngx.HTTP_OK, payload)
end

function Task:created(payload)
	return self:respond(ngx.HTTP_CREATED, payload)
end

function Task:noContent()
	return self:respond(ngx.HTTP_NO_CONTENT, {})
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

function Task:respond(code, payload)
	return {code=code, response=payload}
end

function Task:fail(code, message)
	error({code=code, error=message})
end

return package