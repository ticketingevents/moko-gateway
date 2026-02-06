-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
local First = Task:new()

function First:execute(input)
	local element = {}

  	for field, value in pairs(input) do
		if type(value) ~= "table" or (#value == 0 and next(value) ~= nil) then
		  element = value
		else
		  element = value[1]
		end
	end

	return self:ok(element)
end

return First