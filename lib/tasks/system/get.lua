-- Import Task Base Class
local Task = require "moko.task".Task
local cjson = require "cjson.safe"

-- Define Task Class
Get = Task:new()

function Get:execute(input)
  local uri = input.uri
  
  if uri == nil then
    self:notFound("No request URI was specified.")
  end

  local response = ngx.location.capture(uri)

  if response.status < 300 then
    return self:respond(response.status, cjson.decode(response.body))
  else
    return self:fail(response.status, cjson.decode(response.body))
  end
end

return Get