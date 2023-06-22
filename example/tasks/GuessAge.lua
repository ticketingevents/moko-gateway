-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
GuessAge = Task:new()

function GuessAge:execute(user)
	local service = self:buildService("agify")
	local response = service:get("/", {name=user.name})

	if response.code == 200 then
		return self:ok({age=response.body.age})
	else
		return self:respond(response.code, response.body)
	end
end

return GuessAge