local package = {}
if _REQUIREDNAME == nil then
  workflow = package
else
  _G[_REQUIREDNAME] = package
end
    
-- Import Section
local require = require
local setmetatable = setmetatable
local os = os
local pairs = pairs
local ipairs = ipairs
local error = error
local pcall = pcall
local ngx = ngx
local next = next
local type = type
local string = string
local gmatch  = string.gmatch
local unpack  = table.unpack
local join = require "moko.utilities".join
local cjson = require "cjson.safe"
local rabbitmq = require "resty.rabbitmqstomp"

-- Encapsulate package
setfenv(1, package)

-- Define Workflow Class
Workflow = {}

function Workflow:new(instance)
  instance = instance or {}
  setmetatable(instance, self)

  self.__index = self
  instance.steps = {}

  return instance
end

function Workflow:setup_rabbitmq()
  -- Initialise RabbitMQ connection
  local rabbitmq_connection, initialisation_error = rabbitmq:new({
    username=os.getenv("STOMP_USERNAME"),
    password=os.getenv("STOMP_PASSWORD")
  })

  -- Set RabbitMQ Connection Timeout
  rabbitmq_connection:set_timeout(30000)
  rabbitmq_connection:set_keepalive(10000, 100)

  if not rabbitmq_connection then
    io.stderr:write("Failed to create RabbitMQ client: "..initialisation_error)

    error({
      code=ngx.HTTP_SERVICE_UNAVAILABLE,
      error="The server was unable to communicate with a required upstream service."
    })
  end

  -- Connect to RabbitMQ over STOMP
  local connection_ok, connection_error = rabbitmq_connection:connect(
    os.getenv("STOMP_HOST"),
    os.getenv("STOMP_PORT")
  )

  if not connection_ok then
    io.stderr:write("Failed to connect to RabbitMQ: "..connection_error)

    error({
      code=ngx.HTTP_SERVICE_UNAVAILABLE,
      error="The server was unable to communicate with a required upstream service."
    })
  end

  return rabbitmq_connection
end

function Workflow:add_step(step)
  -- Add workflow step
  self.steps[#self.steps+1] = step
end

function Workflow:run(request)
  local exitCode = 0
  local workspace = {}
  local workflowOutput = {}

  local rabbitmq = self:setup_rabbitmq()

  for i, step in ipairs(self.steps) do
    local stepInput = {}

    if step.input then
      -- Parse request values for step input
      local stepRequestInput, missingRequestInput = self:parseInput(request, step.input)

      -- Parse workspace values for step input
      local stepWorkspaceInput, missingWorkspaceInput = self:parseInput(workspace, step.input)
    
      -- Check if any input could not be found from either source
      local missingInput = {}
      for i, field in ipairs(missingRequestInput) do
        if missingWorkspaceInput[field] ~= nil then
          missingInput[#missingInput+1] = field
        end
      end

      if #missingInput > 0 then
        error({
          code=400,
          error="Missing required request data: "..join(missingInput)
        })

        return
      end

      -- Merge input sources
      for field, value in pairs(stepRequestInput) do
        stepInput[field] = value
      end

      for field, value in pairs(stepWorkspaceInput) do
        stepInput[field] = value
      end

      -- Map any literal input
      for field, value in pairs(step.input) do
        local literal = string.match(value, "literal:(.+)")
        if literal then
          stepInput[field] = literal
        end
      end
    end

    -- Check if conditions for the step are met
    local conditions_met = true

    if step.conditions then
      for comparison, arguments in pairs(step.conditions) do
        for field, value in pairs(arguments) do
          evaluation = false
          if comparison == "equals" then
            evaluation = (cjson.encode(workspace[field])== cjson.encode(value))
          elseif comparison == "not" then
            evaluation = (cjson.encode(workspace[field]) ~= cjson.encode(value))
          end

          conditions_met = conditions_met and evaluation
        end
      end
    end

    -- Execute Step
    if conditions_met then
      -- Iterate through tasks
      local taskInput = stepInput
      local taskOutput = {code=0, format="application/json", response={}}
      local task = {}

      for i, name in pairs(step.tasks) do
        -- Clear task output
        taskOutput = {code=0, format="application/json", response={}}

        -- Attempt to load task from user space
        success, TaskClass = pcall(require, "moko.tasks.user."..name)
        if not success then
          local error_message = TaskClass

          -- Attempt to load system task
          success, TaskClass = pcall(require, "moko.tasks.system."..name)

          -- If no matching task was found
          if not success then
            ngx.log(ngx.ERR, error_message)
            error({code=404, error="Task "..name.." is not defined."})
          end
        end

        -- Create instance of the task
        task = TaskClass:new()

        -- Pipe task output to next task in step. Convert input to list format if necessary
        local singleInput = false
        if (#taskInput == 0 and (next(taskInput) ~= nil or i == 1)) or name == "merge" then
          taskInput = {taskInput}
          singleInput = true
        end

        taskOutput.response = {}
        for i, input in pairs(taskInput) do
          task:init(rabbitmq)
          output = task:execute(input)

          if output.code > 299 then
            error({
              code=output.code,
              error=output.response.error
            })
          end

          if taskOutput.code < output.code then
            taskOutput.code = output.code
          end

          taskOutput.format = output.format
          taskOutput.response[i] = output.response
        end

        -- Assign input for next task
        taskInput = {}
        for i, output in pairs(taskOutput.response) do
          taskInput[i] = output
        end

        -- Convert list to element if necessary
        if singleInput then
          taskInput = taskInput[1]
          taskOutput.response = taskOutput.response[1]
        end
      end

      -- Persist necessary step outputs to workspace
      if step.persist then
        local parsedOutput = self:parseInput(
          {output=taskOutput.response},
          step.persist
        )

        for field, value in pairs(parsedOutput) do
          workspace[field] = value
        end
      end

      -- Set step output as workflow output
      workflowOutput.content = taskOutput.response
      workflowOutput.exitCode = taskOutput.code
      workflowOutput.responseFormat = taskOutput.format
    end
  end

  -- Cleanup RabbitMQ connection
  if rabbitmq ~= nil then
    -- Close RabbitMQ connection
    local disconnection_ok, disconnection_error = rabbitmq:close()

    if not disconnection_ok then
      io.stderr:write("Failed to close RabbitMQ connection: "..disconnection_error)
    end
  end

  return {
    code=workflowOutput.exitCode,
    format=workflowOutput.responseFormat,
    response=workflowOutput.content
  }

end

function Workflow:parseInput(input, mapping)
  local parsedInput = {}
  local missingInput = {}

  for field, template in pairs(mapping) do
    -- Fetch value from input
    parsedInput[field] = input
    for part in gmatch(template, "[^:]+") do
      if parsedInput[field] == nil then
        missingInput[field] = field
      else
        parsedInput[field] = parsedInput[field][part]
      end
    end 
  end

  return parsedInput, missingInput
end

return package