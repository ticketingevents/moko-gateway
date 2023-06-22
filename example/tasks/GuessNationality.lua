-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
GuessNationality = Task:new()

function GuessNationality:execute(user)
	local service = self:buildService("nationalize")
	local response = service:get("/", {name=user.name})

	if response.code == 200 then
		return self:ok({code=response.body.country[1].country_id})
	else
		return self:respond(response.code, response.body)
	end
end

return GuessNationality