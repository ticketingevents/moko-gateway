local package = {}
if _REQUIREDNAME == nil then
	utilities = package
else
	_G[_REQUIREDNAME] = package
end
    
-- Import Section
local type = type
local pairs = pairs
    
-- Encapsulate package
setfenv(1, package)

function join (list, glue)
	if type(list) ~= 'table' then
		return list
	end

	local joined = ""
	for i, element in pairs(list) do
		joined = joined .. element
		if i < #list then
			 joined = joined .. ", "
		end
	end

	return joined
end

return package