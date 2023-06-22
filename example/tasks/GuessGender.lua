-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
GuessGender = Task:new()

function GuessGender:execute(user)
	local service = self:buildService("genderize")
	local response = service:get("/", {name=user.name})

	if response.code == 200 then
		return self:ok({gender=response.body.gender})
	else
		return self:respond(response.code, response.body)
	end
end

return GuessGender