-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
Echo = Task:new()

function Echo:execute(input)
	return self:ok(input)
end

return Echo