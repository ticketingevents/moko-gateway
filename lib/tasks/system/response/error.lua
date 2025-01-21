-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
ErrorResponse = Task:new()

function ErrorResponse:execute(input)
	self:fail(input.code, input.error)
end

return ErrorResponse