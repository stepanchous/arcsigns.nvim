local async = require('gitsigns.async')
local log = require('gitsigns.debug.log')

local asystem = async.wrap(3, require('gitsigns.system').system)

--- @async
--- @param args string[]
--- @param spec? Gitsigns.Git.JobSpec
--- @return string[] stdout, string? stderr, integer code
local function arc_command(args, spec)
  spec = spec or {}

  local cmd = { 'arc' }
  vim.list_extend(cmd, args)

  if spec.text == nil then
    spec.text = true
  end

  --- @type vim.SystemCompleted
  local obj = asystem(cmd, spec)
  async.schedule()

  if not spec.ignore_error and obj.code > 0 then
    log.eprintf(
      "Received exit code %d when running command\n'%s':\n%s",
      obj.code,
      table.concat(cmd, ' '),
      obj.stderr
    )
  end

  local stdout_lines = vim.split(obj.stdout or '', '\n')

  if spec.text then
    if stdout_lines[#stdout_lines] == '' then
      stdout_lines[#stdout_lines] = nil
    end
  end

  if log.verbose then
    log.vprintf('%d lines:', #stdout_lines)
    for i = 1, math.min(10, #stdout_lines) do
      log.vprintf('\t%s', stdout_lines[i])
    end
  end

  if obj.stderr == '' then
    obj.stderr = nil
  end

  return stdout_lines, obj.stderr, obj.code
end

return arc_command
