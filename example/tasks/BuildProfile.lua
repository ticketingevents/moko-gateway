-- Import Task Base Class
local Task = require "moko.task".Task

-- Define Task Class
BuildProfile = Task:new()

function BuildProfile:execute(profile)
	return self:ok({user={profile=profile}})
end

return BuildProfile