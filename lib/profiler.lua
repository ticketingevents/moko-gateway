local package = {}
if _REQUIREDNAME == nil then
  profiler = package
else
  _G[_REQUIREDNAME] = package
end
    
-- Import Section
local setmetatable = setmetatable
local ngx = ngx
local os = os
local pairs = pairs
local string = string
local table = table
local type = type
local error = error
local io = io
local socket = require "socket"
    
-- Encapsulate package
setfenv(1, package)

-- Define Profiler Class
Profiler = {}

-- Define static class variables
__log = {}


function Profiler:new(instance)
  instance = instance or {}
  setmetatable(instance, self)
  self.__index = self

  return instance
end

function Profiler:start(service, endpoint, method)
  if __log[service] == nil then
    __log[service] = {}
  end

  if __log[service][endpoint] == nil then
    __log[service][endpoint] = {}
  end

  if __log[service][endpoint][method] == nil then
    __log[service][endpoint][method] = {
      start=0,
      calls=0,
      elapsed=0
    }
  end

  __log[service][endpoint][method].start = socket.gettime()

  return __log[service][endpoint][method]
end

function Profiler:stop(log)
  log.calls = log.calls + 1
  log.elapsed = log.elapsed + (socket.gettime()-log.start)
  log.start = 0
end

function Profiler:report()
  local method_names = {
    [ngx.HTTP_GET]="GET",
    [ngx.HTTP_POST]="POST",
    [ngx.HTTP_PUT]="PUT",
    [ngx.HTTP_DELETE]="DELETE"
  }

  local report = string.format("\n%-25s", "SERVICE")..
    string.format("%-40s", "ENDPOINT")..
    string.format("%-10s", "METHOD")..
    string.format("%-10s", "CALLS")..
    string.format("%-10s\n", "TIME")

  local calls = 0
  local elapsed = 0

  local services = {}
  for service in pairs(__log) do
    services[#services+1] = service
  end
  table.sort(services)
  for k, service in pairs(services) do
    local endpoints = __log[service]
    for endpoint, methods in pairs(endpoints) do
      for method, log in pairs(methods) do
        report = report..
          string.format("%-25s", service)..
          string.format("%-40s", endpoint)..
          string.format("%-10s", method_names[method])..
          string.format("%-10d", log.calls)..
          string.format("%-.3fs\n", log.elapsed)

        calls = calls + log.calls
        elapsed = elapsed + log.elapsed
      end
    end
  end

  report = report..
    "-------------------------------------------------------------------------------------------\n"..
    string.format("%-25s", "Service Summary")..
    string.format("%-40s", "N/A")..
    string.format("%-10s", "N/A")..
    string.format("%-10d", calls)..
    string.format("%-.3fs\n", elapsed)..
    "-------------------------------------------------------------------------------------------\n"

  io.stderr:write(report)
end

function Profiler:reset()
  __log = {}
end

return package