local package = {}
if _REQUIREDNAME == nil then
	workflow = package
else
	_G[_REQUIREDNAME] = package
end
    
-- Import Section
local require = require
local setmetatable = setmetatable
local pairs = pairs
local ipairs = ipairs
local error = error
local pcall = pcall
local ngx = ngx
local next = next
local gmatch  = string.gmatch
local unpack  = table.unpack
local join = require "moko.utilities".join
local cjson = require "cjson.safe"

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

function Workflow:add_step(step)
	-- Add workflow step
	self.steps[#self.steps+1] = step
end

function Workflow:run(request)
  local stepInput = {}
	local stepOutput = {}
	local exitCode = 0

	for i, step in ipairs(self.steps) do
		-- Reset step output
		stepOutput = {}

		-- Parse step input values for pipeline input
		local pipelineRequestInput, missingRequestInput = self:parseInput(request, step)

    -- Parse request values for pipeline input
    local pipelineStepInput, missingStepInput = self:parseInput(stepInput, step)

    -- Check if any input could not be found from either source
    local missingInput = {}
    for i, field in ipairs(missingRequestInput) do
      if missingStepInput[field] ~= nil then
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
    local pipelineInput = {}

    for field, value in pairs(pipelineRequestInput) do
      pipelineInput[field] = value
    end

    for field, value in pairs(pipelineStepInput) do
      pipelineInput[field] = value
    end

		-- Execute Pipelines
		for label, pipeline in pairs(step["pipelines"]) do
			-- Prepare task input
			local taskInput = {}

			-- Filter out pipeline input for requested fields
			for i, field in pairs(pipeline["input"]) do
				taskInput[field] = pipelineInput[field]
			end

			-- Iterate through pipeline's tasks
			local taskOutput = {code=0, response={}}
			local task = {}

			for i, name in pairs(pipeline["tasks"]) do
				-- Clear task output
				taskOutput = {code=0, response={}}

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

				-- Pipe task output to next task in pipeline

        -- Convert input to list format if necessary
        local singleInput = false
        if #taskInput == 0 then
          taskInput = {taskInput}
          singleInput = true
        end

        taskOutput.response = {}
        for i, input in pairs(taskInput) do
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

			-- Assign final task output to step output
			stepOutput[label] = taskOutput.response

      -- Convert to list for processing
      local singleOutput = false
      if #stepOutput[label] == 0 then
        stepOutput[label] = {stepOutput[label]}
        singleOutput = true
      end

      -- If there are any step output filters, apply them
      if step["filters"] then
        for i, output in ipairs(stepOutput[label]) do
          local filteredOutput = {}

          for j, filter in pairs(step["filters"]) do
            filteredOutput[filter] = stepOutput[label][i][filter]
          end

          stepOutput[label][i] = filteredOutput
        end
      end

      -- Convert list to element if necessary
      if singleOutput then
        stepOutput[label] = stepOutput[label][1]
      end

			exitCode = taskOutput.code
		end

		-- If there was no step output pass-through input
		if next(stepOutput) == nil then
			stepOutput["pass"] = pipelineInput
		end

		-- Pipe step output into the subsequent step
		stepInput = stepOutput
	end

	-- Simple aggregation of last step pipeline outputs
	local workflowOutput = {}
	for pipeline, output in pairs(stepOutput) do
		for key, value in pairs(output) do
			workflowOutput[key] = value
		end
	end

	return {code=exitCode, response=workflowOutput}
end

function Workflow:parseInput(input, step)
  local templates = step["data"]
  local parsedInput = {}
  local missingInput = {}

  for field, template in pairs(templates) do
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