-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
LookupCountry = Task:new()

function LookupCountry:execute(country)
	local service = self:buildService("restcountries")
	local response = service:get("/alpha/"..country.code)

	if response.code == 200 then
		return self:ok({demonym=response.body[1].demonyms.eng.m})
	else
		return self:respond(response.code, response.body)
	end
end

return LookupCountry