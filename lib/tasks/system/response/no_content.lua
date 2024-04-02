-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
NoContent = Task:new()

function NoContent:execute()
	return self:noContent()
end

return NoContent