-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
Spread = Task:new()

function Spread:execute(input)
  local list = {}

  for field, value in pairs(input) do
    if type(value) ~= "table" or (#value == 0 and next(value) ~= nil) then
      list = {value}
    else
      list = value
    end
  end

  return self:ok(list)
end

return Spread