local package = {}
if _REQUIREDNAME == nil then
	routing = package
else
	_G[_REQUIREDNAME] = package
end
    
-- Import Section
local require = require
local setmetatable = setmetatable
local ngx = ngx
local io = io
local string = string
local cjson = require "cjson.safe"
local pairs = pairs
local gsub  = string.gsub
local gmatch  = string.gmatch
local Workflow = require "moko.workflow".Workflow
local pcall = pcall
local type = type

-- Private functions
local join = function(list, glue)
	local joined = ""
	for i, element in pairs(list) do
		joined = joined .. element
		if i < #list then
			 joined = joined .. ", "
		end
	end

	return joined
end
    
-- Encapsulate package
setfenv(1, package)

-- Define Router Class
Router = {}

function Router:new(instance)
	instance = instance or {}
	setmetatable(instance, self)

	self.__index = self
	self.route = require "resty.route".new()

	-- Load endpoint default and definitions
	endpointFile = io.open("/home/moko/project/conf/endpoints.yaml")
	endpointDefinitions = require "yaml".eval(
		string.gsub(endpointFile:read("*all"), "\n\n", "\n")
	)

	self.defaults = endpointDefinitions["defaults"] or {}
	self.endpoints = endpointDefinitions["endpoints"] or {}

	-- Load workflow definitions
	workflowFile = io.open("/home/moko/project/conf/workflows.yaml")
	workflowDefinitions = require "yaml".eval(
		string.gsub(workflowFile:read("*all"), "\n\n", "\n")
	)

	self.workflows = workflowDefinitions["workflows"] or {}

	return instance
end

function Router:initialise()
	-- Add endpoint routes
	for name, endpoint in pairs(self.endpoints) do
		-- Initialise methods table with defaults
		local methods = {}
		for method, definition in pairs(self.defaults.methods) do
			methods[method] = {
				workflow = definition.workflow or nil,
				restrictions = definition.restrictions or nil
			}
		end

		-- Override default methods with user definitions
		for method, definition in pairs(endpoint.methods) do
			methods[method].workflow = definition.workflow or methods[method].workflow
			methods[method].restrictions = definition.restrictions or methods[method].restrictions
		end
		
		for method, definition in pairs(methods) do
			-- Setup Route Handler
			self.route(
				method,
				"@"..gsub(endpoint.uri, ":%a+", ":string"),
				self:buildHandler(definition, endpoint)
			)
		end
	end

	-- Create catch-all route for non-existant endpoints
	self.route(
		function(router)
			local error = "The requested endpoint ".. ngx.var.uri .." does not exist on this server."
			router:json({message = error})
		end
	)
end

function Router:handleCors(endpoint)
	local settings = {}

	-- Load default CORS settings
	for setting, value in pairs(self.defaults.cors or {}) do
		if type(value) == 'table' then
			if settings[setting] == nil then
				settings[setting] = {}
			end

			for subsetting, subvalue in pairs(value) do
				settings[setting][subsetting] = subvalue
			end
		else
			settings[setting] = value
		end
	end

	-- Override endpoint specific settings
	for setting, value in pairs(endpoint.cors or {}) do
		if type(value) == 'table' then
			for subsetting, subvalue in pairs(value) do
				settings[setting][subsetting] = subvalue
			end
		else
			settings[setting] = value
		end
	end

	self.route.filter ("@"..gsub(endpoint.uri, ":%a+", ":string")) (
		function(router)	
			ngx.header["Access-Control-Allow-Origin"] = settings.origin or nil;
	    ngx.header["Access-Control-Allow-Credentials"] = settings.origin and "true";
	    ngx.header["Access-Control-Allow-Methods"] = join(settings.methods, ", ") or nil;
	    ngx.header["Access-Control-Allow-Headers"] = join(settings.headers.request, ", ") or nil;
	    ngx.header["Access-Control-Expose-Headers"] = join(settings.headers.response, ", ") or nil;
	    ngx.header["Access-Control-Max-Age"] = settings.lifetime or nil;
		end
	)
end

function Router:buildRequest(uri, arg)
	-- Build request object for workflow input
	local request = {
		uri = {},
		headers = ngx.req.get_headers(),
		query = ngx.req.get_uri_args(),
		body = cjson.decode(ngx.req.get_body_data())
	}

	-- Parse endpoint URI
	local i = 1
	for part in gmatch(uri, ":(%a+)") do
		request.uri[part] = arg[i]
		i = i+1
	end

	return request
end

function Router:buildHandler(method, endpoint)
	-- Handle CORS if settings are provided
	self:handleCors(endpoint)

	return function(router, ...)
		-- Assemble request to input to workflow
		local request = self:buildRequest(endpoint.uri, {...})

		-- If endpoint is restrictionsed run authentication workflow
		if method.restrictions then
			local authenticated, user = self:runWorkflow(
				method.restrictions.authenticate,
				request
			)
		
			if authenticated then
				-- Check that the authenticated user has access
				local allowedValue = nil
				for i, tag in pairs(method.restrictions.allow) do
					-- Get allowed user value
					local parts = {}
					for part in gmatch(tag, "[^:]+") do
						parts[#parts+1] = part
					end

					local key = parts[1]
					local value = parts[2]

					-- Check that user has allowed value
					if user.response[key] ~= value then
						ngx.status = ngx.HTTP_FORBIDDEN
						router:json({error="You are restricted from accessing this resource"})
						return
					end
				end
			else
					ngx.status = ngx.HTTP_UNAUTHORIZED
					router:json({error="Your request could not be authenticated."})
					return
			end
		end

		-- Execute main endpoint workflow
		local success, output = self:runWorkflow(method.workflow, request)
		
		-- Report success or error as necessary
		if success then
			ngx.status = output.code
			router:json(output.response)
		else
			if type(output) == "table" then
				ngx.status = output.code
				router:json({error=output.error})
			else
				ngx.status = 500
				router:json({error="There was a server error while excuting this request. Please see system logs for details."})
				ngx.log(ngx.ERR, output)
			end
		end
	end
end

function Router:runWorkflow(label, request)
	-- Check if workflow exists
	if self.workflows[label] then

		-- Create workflow
		local workflow = Workflow:new()

		-- Add workflow steps
		for i, step in pairs(self.workflows[label].steps) do
			workflow:add_step(step)
		end

		-- Run workflow
		return pcall(workflow.run, workflow, request)
	else
		-- The workflow couldn't be found
		ngx.status = 500
		router:json({error="There was a server error while excuting this request. Please see system logs for details."})
		ngx.log(ngx.ERR, "Can't find tye '"..label.."' workflow specified for endpoint: "..ngx.var.uri)
	end
end

function Router:dispatch()
	self.route :dispatch()
end

return package