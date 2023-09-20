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
local join = require "moko.utilities".join
local pcall = pcall
local type = type
    
-- Encapsulate package
setfenv(1, package)

-- Define Router Class
Router = {}

function Router:new(instance)
	instance = instance or {}
	setmetatable(instance, self)

	self.__index = self
	instance.route = require "resty.route".new()

	-- Load endpoint default and definitions
	endpointFile = io.open("/home/moko/project/conf/endpoints.yaml")
	endpointDefinitions = require "yaml".eval(
		string.gsub(endpointFile:read("*all"), "\n\n", "\n")
	)

	instance.defaults = endpointDefinitions["defaults"] or {}
	instance.endpoints = endpointDefinitions["endpoints"] or {}

	-- Load workflow definitions
	workflowFile = io.open("/home/moko/project/conf/workflows.yaml")
	workflowDefinitions = require "yaml".eval(
		string.gsub(workflowFile:read("*all"), "\n\n", "\n")
	)

	instance.workflows = workflowDefinitions["workflows"] or {}

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
				guard = definition.guard or nil,
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
		-- Assemble request to input to workflows
		local request = self:buildRequest(endpoint.uri, {...})

		-- Run guard workflow to determine if route can be run
		if method.guard then
			local success, output = self:runWorkflow(
				method.guard,
				request,
        router
			)

			if success then
				-- Block request if the workflow returned an error code
				if output.code > 299 then
					ngx.status = output.code
					router:json(output.response)
					return
				end
			else
				self:logError(router, output)
				return
			end
		end

		-- If endpoint is restrictionsed run authentication workflow
		if method.restrictions then
			local authenticated, user = self:runWorkflow(
				method.restrictions.authenticate,
				request,
        router
			)
		
			if authenticated then
				-- Check that the authenticated user has access
				for field, criteria in pairs(method.restrictions.allow) do
          -- Case criteria to table if necessary
          if type(criteria) ~= 'table' then
            criteria = {criteria}
          end

          -- Check that the user matches at least one value for this criteria
          local matching_criteria = false

          for i, value in pairs(criteria) do
  					-- Check that user has allowed value
  					if user.response[field] == value then
              matching_criteria = true
  					end
          end

          -- If the user matches no values for this criteria they don't have access
          if matching_criteria == false then
            ngx.status = ngx.HTTP_FORBIDDEN
            router:json({error="You are restricted from accessing this resource"})
            return
          end
				end

        -- If user is authorised assign their details to the request
        request.user = user.response
			else
					ngx.status = ngx.HTTP_UNAUTHORIZED
					router:json({error="Your request could not be authenticated."})
					return
			end
		end

		-- Execute main endpoint workflow
		local success, output = self:runWorkflow(method.workflow, request, router)
		
		-- Report success or error as necessary
		if success then
			ngx.status = output.code
			router:json(output.response)
		else
			self:logError(router, output)
		end
	end
end

function Router:runWorkflow(label, request, router)
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

    return {false, nil}
	end
end

function Router:dispatch()
	self.route :dispatch()
end

function Router:logError(router, error)
	if type(error) == "table" then
		ngx.status = error.code
		router:json({error=error.error})
	else
		ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
		router:json({error="There was a server error while excuting this request. Please see system logs for details."})
		ngx.log(ngx.ERR, error)
	end
end

return package