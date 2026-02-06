-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
Merge = Task:new()

function Merge:execute(input)
  local merged = {}

  for i, entry in ipairs(input) do
		if #entry == 0 and (next(entry) ~= nil or i == 1) then
			for key, value in pairs(entry) do
				merged[key] = value
			end
		else
			merged[#merged+1] = entry
		end
  end

  return self:ok(merged)
end

return Merge