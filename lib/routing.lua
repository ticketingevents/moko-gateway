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
local os = os
local io = io
local string = string
local tonumber = tonumber
local cjson = require "cjson.safe"
local jsonschema = require "jsonschema"
local pairs = pairs
local ipairs = ipairs
local gsub  = string.gsub
local gmatch  = string.gmatch
local Workflow = require "moko.workflow".Workflow
local join = require "moko.utilities".join
local pcall = pcall
local type = type
local Cache = require "moko.cache".Cache
local Profiler = require "moko.profiler".Profiler

-- Formatting options
cjson.encode_empty_table_as_object(false)

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

    instance.authentication = endpointDefinitions["authentication"] or nil
    instance.cors = endpointDefinitions["cors"] or nil
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
    for endpoint, methods in pairs(self.endpoints) do
        -- Initialise methods table with defaults
        local definitions = {}
        for method, definition in pairs(self.defaults.methods) do
            definitions[method] = {
                workflow = definition.workflow or nil,
                guard = definition.guard or nil
            }
        end

        -- Override default methods with user definitions
        for method, definition in pairs(methods) do
            definitions[method].workflow = definition.workflow or definitions[method].workflow
            definitions[method].access = definition.access or cjson.decode(definitions[method].access)

            -- Compile and cache parameters schema validator if one is specified
            if definition.parameters then
                definitions[method].parameter_validator = jsonschema.generate_validator(
                    self:parse_schema(definition.parameters)
                )
            end

            -- Compile and cache request schema validator if one is specified
            if definition.request then
                definitions[method].request_validator = jsonschema.generate_validator(
                    self:parse_schema(definition.request)
                )
            end
        end
        
        for method, definition in pairs(definitions) do
            -- Setup Route Handler
            self.route(
                method,
                "@"..gsub(endpoint, ":%a+", ":string"),
                self:buildHandler(endpoint, definition)
            )
        end
    end

    -- Create catch-all route for non-existant endpoints
    self.route(
        function(router)
            local error = "The requested endpoint ".. ngx.var.uri .." does not exist on this server."

            ngx.status = ngx.HTTP_NOT_FOUND
            router:json({message = error})
        end
    )
end

function Router:handleCors(endpoint)
    local settings = {}

    -- Load CORS settings
    for setting, value in pairs(self.cors or {}) do
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

    self.route.filter ("@"..gsub(endpoint, ":%a+", ":string")) (
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
        method = ngx.req.get_method(),
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

function Router:buildHandler(endpoint, method)
    -- Handle CORS if settings are provided
    self:handleCors(endpoint)

    return function(router, ...)
        -- Validate parameters before proceeding
        if method.request_validator ~= nil then
            local parameters = {}
            for parameter, value in pairs(ngx.req.get_uri_args()) do
                if tonumber(value) ~= nil then
                    parameters[parameter] = tonumber(value)
                elseif value == "true" or value == "false" then
                    parameters[parameter] = (value == "true" and true or false)
                else
                    parameters[parameter] = value
                end
            end
            
            ok, error = method.parameter_validator(parameters)
            if not ok then
                ngx.log(ngx.ERR, error)
                ngx.status = ngx.HTTP_BAD_REQUEST
                router:json({
                    error="Your request parameters are invalid. "..
                    "Please ensure you have included any required parameters "..
                    "and values are well-formed."
                })

                return
            end
        end

        -- Validate request body before proceeding
        if method.request_validator ~= nil then
            local body = cjson.decode(ngx.req.get_body_data())
            
            ok, error = method.request_validator(body)
            if not ok then
                ngx.log(ngx.ERR, error)
                ngx.status = ngx.HTTP_BAD_REQUEST
                router:json({
                    error="Your request payload is invalid. "..
                    "Please ensure you have included all required fields "..
                    "and values are well-formed."
                })

                return
            end
        end

        -- Assemble request to input to workflows
        local request = self:buildRequest(endpoint, {...})

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

        -- If endpoint is restricted run authentication workflow
        if self.authentication then
            local authenticated, access = self:runWorkflow(
                self.authentication.workflow,
                request,
                router
            )
        
            if authenticated then
                -- Check that the return access matches the defined access requirements
                local has_access = false
                for i, permission in ipairs(method.access) do
                    has_access = has_access or (access.response[self.authentication.access] == permission)
                end

                if not has_access then
                    ngx.status = ngx.HTTP_FORBIDDEN
                    router:json({error="You are restricted from accessing this resource"})
                    return
                end

                -- If user is authorised assign their details to the request
                request.user = access.response
            else
                self:logError(router, access)
                return
            end
        end

        -- Execute main endpoint workflow
        local success, output = self:runWorkflow(method.workflow, request, router)
        
        -- Print profiling information (if enabled)
        local profiler = Profiler:new()
        if os.getenv("PROFILING") == "on" and ngx.req.get_uri_args()["profile"] ~= nil then
            profiler:report()
        end

        -- Reset profiling information
        profiler:reset()

        -- Report success or error as necessary
        if success then
            ngx.status = output.code

            if output.format == "application/json" then
                router:json(output.response)
            else
                ngx.header["Content-Type"] = output.format;
                ngx.say(output.response.data)
            end
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
            -- Handle workflow injection steps
            if step.inject ~= nil then
                -- Load injected workflow
                local injected_workflow = self.workflows[step.inject.workflow]

                -- Add injected steps to workflow
                for j, injected_step in pairs(injected_workflow.steps) do
                    -- Create substitute step
                    local new_step = {
                        data={},
                        pipelines=injected_step.pipelines,
                        conditions=injected_step.conditions,
                        filters=injected_step.filters
                    }

                    -- Map injected workflow data
                    for field, value in pairs(injected_step.data) do
                        new_step.data[field] = injected_step.data[field]
                        if value == "inject" then
                            new_step.data[field] = step.inject.data[field]
                        end
                    end
                    
                    -- Inject step to workflow
                    workflow:add_step(new_step)
                end
            else
                workflow:add_step(step)
            end
        end

        -- Run workflow
        return pcall(workflow.run, workflow, request)
    else
        -- The workflow couldn't be found
        ngx.status = 500
        router:json({error="There was a server error while excuting this request. Please see system logs for details."})
        ngx.log(ngx.ERR, "Can't find the '"..label.."' workflow specified for endpoint: "..ngx.var.uri)

        return {false, nil}
    end
end

function Router:dispatch()
    -- Clear cache for each route
    local cache = Cache:new()
    cache:clear()

    self.route:dispatch()
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

function Router:parse_schema(config)
    local request_schema = {
        type = "object",
        properties = {},
        required = {},
        additionalProperties = false
    }

    for field, properties in pairs(config) do
        local type = string.match(properties, "^(%w+)")
        local attributes = string.match(properties, "%(([^%)]+)%)")
        
        if type ~= nil then
            request_schema.properties[field] = {type = type}
        end

        if attributes ~= nil then
            for attribute in attributes:gmatch("([^%|]+)") do
                local name = string.match(attribute, "([^=]+)")
                local value = string.match(attribute, "=(.+)")

                if name == "required" then
                    request_schema.required[#request_schema.required+1] = field
                elseif name == "enum" then
                    request_schema.properties[field][name] = cjson.decode(value)
                else
                    request_schema.properties[field][name] = value
                end
            end
        end
    end

    return request_schema
end

return package