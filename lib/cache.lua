local package = {}
if _REQUIREDNAME == nil then
  task = package
else
  _G[_REQUIREDNAME] = package
end
    
-- Import Section
local setmetatable = setmetatable
local ngx = ngx
local pairs = pairs
local type = type
local error = error
    
-- Encapsulate package
setfenv(1, package)

-- Define Task Class
Cache = {}
__cache = {}

function Cache:new(instance)
  instance = instance or {}
  setmetatable(instance, self)
  self.__index = self

  return instance
end

function Cache:insert(key, value)
  __cache[key] = value
end

function Cache:retrieve(key)
  if __cache[key] ~= nil then
    return self:__copy(__cache[key])
  else
    return false
  end
end

function Cache:clear()
  __cache = {}
end

function Cache:__copy(from)
  local copy = {}
  for k,v in pairs(from) do
    if type(v) == "table" then
      copy[k] = self:__copy(v)
    else
      copy[k] = v
    end
  end

  return copy
end

return package