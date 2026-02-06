-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
List = Task:new()

function List:execute(input)
  local list = {}
  local elements = {}

  for key, value in pairs(input) do
  	elements[#elements+1] = value
  end

  if #elements == 1 then
  	if type(elements[1]) == "table" then
  		list = elements[1]
  	else
  		list = {elements[1]}
  	end
  elseif #elements > 1 then
  	list = {input}
  end

  return self:ok(list)
end

return List