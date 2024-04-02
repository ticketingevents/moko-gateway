-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
Created = Task:new()

function Created:execute(input)
  return self:created(input)
end

return Created