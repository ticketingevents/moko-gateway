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

function Workflow:run(stepInput)
	local stepOutput = {}
	local exitCode = 0

	for i, step in ipairs(self.steps) do
		-- Reset step output
		stepOutput = {}

		-- Initialise pipeline input
		local pipelineInput = {}
		local missingInput = {}
		for field, template in pairs(step["data"]) do
			-- Fetch value from input
			pipelineInput[field] = stepInput
			for part in gmatch(template, "[^:]+") do
				if pipelineInput[field] == nil then
					missingInput[#missingInput+1] = field
				else
					pipelineInput[field] = pipelineInput[field][part]
				end
			end 
		end

		if #missingInput > 0 then
			error({
				code=400,
				error="Missing required request data: "..join(missingInput)
			})

			return
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
			local taskOutput = {}
			local task = {}

			for i, name in pairs(pipeline["tasks"]) do
				-- Clear task output
				taskOutput = {}

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
				taskOutput = task:execute(taskInput)
				taskInput = taskOutput.response

				if taskOutput.code > 299 then
					error({code=taskOutput.code, error=taskOutput.response.error})
				end
			end

			-- Assign final task output to step output
			stepOutput[label] = taskOutput.response

      -- If there are any step output filters, apply them
      if step["filters"] then
        local filteredOutput = {}
        for i, filter in pairs(step["filters"]) do
          filteredOutput[filter] = stepOutput[label][filter]
        end

        stepOutput[label] = filteredOutput
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

return package