-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
Echo = Task:new()

function Echo:execute(input)
  local count = 0
  for _ in pairs(input) do count = count + 1 end

  local output = input

  -- If there is only one input entry, echo its contents instead
  if count == 1 then
    for k in pairs(input) do
      output = input[k]
    end
  end

	return self:ok(output)
end

return Echo