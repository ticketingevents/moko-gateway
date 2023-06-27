-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
Echo = Task:new()

function Echo:execute(input)
	local output = input
	return self:ok(output)
end

return Echo