-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
MethodNotAllowed = Task:new()

function MethodNotAllowed:execute()
	local uri = ngx.var.request_uri
	local method = ngx.req.get_method()

	return self:notAllowed(
		"The "..uri.." endpoint does not support the "..method.." method"
	)
end

return MethodNotAllowed