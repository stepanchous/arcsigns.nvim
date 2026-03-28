local async = require('gitsigns.async')
local Hunks = require('gitsigns.hunks')
local manager = require('gitsigns.manager')
local util = require('gitsigns.util')

local config = require('gitsigns.config').config
local cache = require('gitsigns.cache').cache

local api = vim.api
local current_buf = api.nvim_get_current_buf

--- @class gitsigns.actions
local M = {}

--- @class Gitsigns.CmdParams.Smods
--- @field vertical boolean
--- @field split 'aboveleft'|'belowright'|'topleft'|'botright'

--- @class Gitsigns.CmdArgs
--- @field vertical? boolean
--- @field split? boolean
--- @field global? boolean
--- @field [integer] any

--- @class Gitsigns.CmdParams : vim.api.keyset.create_user_command.command_args
--- @field smods Gitsigns.CmdParams.Smods

--- @class (exact) Gitsigns.HunkOpts
--- Operate on/select all contiguous hunks. Only useful if 'diff_opts'
--- contains `linematch`. Defaults to `true`.
--- @field greedy? boolean

--- Variations of functions from M which are used for the Gitsigns command
--- @type table<string,fun(args: Gitsigns.CmdArgs, params: Gitsigns.CmdParams)>
local C = {}

--- Completion functions for the respective actions in C
local CP = {}

--- @generic T
--- @param callback? fun(err?: string)
--- @param func async fun(...:T...) # The async function to wrap
--- @return Gitsigns.async.Task
local function async_run(callback, func, ...)
  assert(type(func) == 'function')

  local task = async.run(func, ...)

  if callback and type(callback) == 'function' then
    task:await(callback)
  else
    task:raise_on_error()
  end

  return task
end

--- Detach Gitsigns from all buffers it is attached to.
function M.detach_all()
  require('gitsigns.attach').detach_all()
end

--- Detach Gitsigns from the buffer {bufnr}. If {bufnr} is not
--- provided then the current buffer is used.
---
--- @param bufnr integer Buffer number
function M.detach(bufnr)
  require('gitsigns.attach').detach(bufnr)
end

--- Attach Gitsigns to the buffer.
---
--- Attributes:
--- - {async}
---
--- @param bufnr integer Buffer number
--- @param ctx Gitsigns.GitContext?
---   Git context data that may optionally be used to attach to any buffer that represents a git
---   object.
--- @param trigger? string
--- @param callback? fun(err?: string)
function M.attach(bufnr, ctx, trigger, callback)
  async_run(callback, require('gitsigns.attach').attach, bufnr or current_buf(), ctx, trigger)
end

--- Toggle [[gitsigns-config-signbooleancolumn]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[gitsigns-config-signcolumn]]
function M.toggle_signs(value)
  if value ~= nil then
    config.signcolumn = value
  else
    config.signcolumn = not config.signcolumn
  end
  return config.signcolumn
end

--- Toggle [[gitsigns-config-numhl]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
---
--- @return boolean : Current value of [[gitsigns-config-numhl]]
function M.toggle_numhl(value)
  if value ~= nil then
    config.numhl = value
  else
    config.numhl = not config.numhl
  end
  return config.numhl
end

--- Toggle [[gitsigns-config-linehl]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[gitsigns-config-linehl]]
M.toggle_linehl = function(value)
  if value ~= nil then
    config.linehl = value
  else
    config.linehl = not config.linehl
  end
  return config.linehl
end

--- Toggle [[gitsigns-config-word_diff]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[gitsigns-config-word_diff]]
function M.toggle_word_diff(value)
  if value ~= nil then
    config.word_diff = value
  else
    config.word_diff = not config.word_diff
  end
  -- Don't use refresh() to avoid flicker
  util.redraw({ buf = 0, range = { vim.fn.line('w0') - 1, vim.fn.line('w$') } })
  return config.word_diff
end

--- Toggle [[gitsigns-config-current_line_blame]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[gitsigns-config-current_line_blame]]
function M.toggle_current_line_blame(value)
  if value ~= nil then
    config.current_line_blame = value
  else
    config.current_line_blame = not config.current_line_blame
  end
  return config.current_line_blame
end

--- @deprecated Use [[gitsigns.preview_hunk_inline()]]
--- Toggle [[gitsigns-config-show_deleted]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[gitsigns-config-show_deleted]]
function M.toggle_deleted(value)
  if value ~= nil then
    config.show_deleted = value
  else
    config.show_deleted = not config.show_deleted
  end
  return config.show_deleted
end

--- @async
--- @param bufnr integer
local function update(bufnr)
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  manager.update(bufnr)
end

--- Jump to hunk in the current buffer. If a hunk preview
--- (popup or inline) was previously opened, it will be re-opened
--- at the next hunk.
---
--- Attributes:
--- - {async}
---
--- @param direction 'first'|'last'|'next'|'prev'
--- @param opts Gitsigns.NavOpts? Configuration options.
--- @param callback? fun(err?: string)
function M.nav_hunk(direction, opts, callback)
  async_run(callback, function()
    --- @cast opts Gitsigns.NavOpts?
    require('gitsigns.actions.nav').nav_hunk(direction, opts)
  end)
end

function C.nav_hunk(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.nav_hunk(args[1], args)
end

--- @deprecated use [[gitsigns.nav_hunk()]]
--- Jump to the next hunk in the current buffer.
---
--- See [[gitsigns.nav_hunk()]].
---
--- Attributes:
--- - {async}
function M.next_hunk(opts, callback)
  async_run(callback, function()
    require('gitsigns.actions.nav').nav_hunk('next', opts)
  end)
end

function C.next_hunk(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.nav_hunk('next', args)
end

--- @deprecated use [[gitsigns.nav_hunk()]]
--- Jump to the previous hunk in the current buffer.
---
--- See [[gitsigns.nav_hunk()]].
---
--- Attributes:
--- - {async}
function M.prev_hunk(opts, callback)
  async_run(callback, function()
    require('gitsigns.actions.nav').nav_hunk('prev', opts)
  end)
end

function C.prev_hunk(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.nav_hunk('prev', args)
end

--- Select the hunk under the cursor.
---
--- @param opts Gitsigns.HunkOpts? Additional options.
function M.select_hunk(opts)
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  opts = opts or {}

  local hunk --- @type Gitsigns.Hunk.Hunk?
  async
    .run(function()
      hunk = bcache:get_hunk(nil, opts.greedy ~= false)
    end)
    :wait()

  if not hunk then
    return
  end

  if vim.fn.mode():find('v') ~= nil then
    vim.cmd('normal! ' .. hunk.added.start .. 'GoV' .. hunk.vend .. 'G')
  else
    vim.cmd('normal! ' .. hunk.added.start .. 'GV' .. hunk.vend .. 'G')
  end
end

--- Get hunk array for specified buffer.
---
--- @param bufnr integer Buffer number, if not provided (or 0)
---             will use current buffer.
--- @return table? : Array of hunk objects.
---   Each hunk object has keys:
---   - `"type"`: String with possible values: "add", "change",
---     "delete"
---   - `"head"`: Header that appears in the unified diff
---     output.
---   - `"lines"`: Line contents of the hunks prefixed with
---     either `"-"` or `"+"`.
---   - `"removed"`: Sub-table with fields:
---     - `"start"`: Line number (1-based)
---     - `"count"`: Line count
---   - `"added"`: Sub-table with fields:
---     - `"start"`: Line number (1-based)
---     - `"count"`: Line count
M.get_hunks = function(bufnr)
  if (bufnr or 0) == 0 then
    bufnr = current_buf()
  end
  if not cache[bufnr] then
    return
  end
  local ret = {} --- @type Gitsigns.Hunk.Hunk_Public[]
  -- TODO(lewis6991): allow this to accept a greedy option
  for _, h in ipairs(cache[bufnr].hunks or {}) do
    ret[#ret + 1] = {
      head = h.head,
      lines = Hunks.patch_lines(h, vim.bo[bufnr].fileformat),
      type = h.type,
      added = h.added,
      removed = h.removed,
    }
  end
  return ret
end

--- Run git blame on the current line and show the results in a
--- floating window. If already open, calling this will cause the
--- window to get focus.
---
--- Attributes:
--- - {async}
---
--- @param opts Gitsigns.LineBlameOpts? Additional options.
--- @param callback? fun(err?: string)
function M.blame_line(opts, callback)
  --- @cast opts Gitsigns.LineBlameOpts?
  async_run(callback, require('gitsigns.actions.blame_line'), opts)
end

C.blame_line = function(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.blame_line(args)
end

--- Run git-blame on the current file and open the results
--- in a scroll-bound vertical split.
---
--- Attributes:
--- - {async}
---
--- @param opts Gitsigns.BlameOpts? Additional options.
--- @param callback? fun(err?: string)
function M.blame(opts, callback)
  async_run(callback, require('gitsigns.actions.blame').blame, opts)
end

--- @async
--- @param bcache Gitsigns.CacheEntry
--- @param base string?
local function update_buf_base(bcache, base)
  bcache.file_mode = base == 'FILE'
  if not bcache.file_mode then
    bcache.git_obj:change_revision(base)
  end
  bcache:invalidate(true)
  update(bcache.bufnr)
end

--- Change the base revision to diff against. If {base} is not
--- given, then the original base is used. If {global} is given
--- and true, then change the base revision of all buffers,
--- including any new buffers.
---
--- Attributes:
--- - {async}
---
--- Examples:
--- ```lua
---   -- Change base to 1 commit behind head
---   require('gitsigns').change_base('HEAD~1')
---   -- :Gitsigns change_base HEAD~1
---
---   -- Also works using the Gitsigns command
---   :Gitsigns change_base HEAD~1
---
---   -- Other variations
---   require('gitsigns').change_base('~1')
---   -- :Gitsigns change_base ~1
---   require('gitsigns').change_base('~')
---   -- :Gitsigns change_base ~
---   require('gitsigns').change_base('^')
---   -- :Gitsigns change_base ^
---
---   -- Commits work too
---   require('gitsigns').change_base('92eb3dd')
---   -- :Gitsigns change_base 92eb3dd
---
---   -- Revert to original base
---   require('gitsigns').change_base()
---   -- :Gitsigns change_base
--- ```
---
--- For a more complete list of ways to specify bases, see
--- [[gitsigns-revision]].
---
--- @param base string? The object/revision to diff against.
--- @param global boolean? Change the base of all buffers.
--- @param callback? fun(err?: string)
function M.change_base(base, global, callback)
  async_run(callback, function()
    base = util.norm_base(base)

    if global then
      config.base = base

      for _, bcache in pairs(cache) do
        update_buf_base(bcache, base)
      end
    else
      local bufnr = current_buf()
      local bcache = cache[bufnr]
      if not bcache then
        return
      end

      update_buf_base(bcache, base)
    end
  end)
end

C.change_base = function(args, _)
  M.change_base(args[1], (args[2] or args.global))
end

--- Reset the base revision to diff against back to the
--- index.
---
--- Alias for `change_base(nil, {global})` .
M.reset_base = function(global)
  M.change_base(nil, global)
end

C.reset_base = function(args, _)
  M.change_base(nil, (args[1] or args.global))
end

--- Get all the available line specific actions for the current
--- buffer at the cursor position.
---
--- @return table|nil : Dictionary of action name to function which when called
---     performs action.
M.get_actions = function()
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end
  local hunk = bcache:get_cursor_hunk()

  --- @type string[]
  local actions_l = {}

  if hunk then
    vim.list_extend(actions_l, {
      'select_hunk',
    })
  else
    actions_l[#actions_l + 1] = 'blame_line'
  end

  local actions = {} --- @type table<string,function>
  for _, a in ipairs(actions_l) do
    actions[a] = M[a] --[[@as function]]
  end

  return actions
end

for name, f in
  pairs(M --[[@as table<string,function>]])
do
  if vim.startswith(name, 'toggle') then
    C[name] = function(args)
      f(args[1])
    end
  end
end

--- Refresh all buffers.
---
--- Attributes:
--- - {async}
---
--- @param callback? fun(err?: string)
function M.refresh(callback)
  manager.reset_signs()
  require('gitsigns.highlight').setup_highlights()
  require('gitsigns.current_line_blame').setup()
  async_run(callback, function()
    for k, v in pairs(cache) do
      v:invalidate(true)
      manager.update(k)
    end
  end)
end

--- @param name string
--- @return fun(args: table, params: Gitsigns.CmdParams)
function M._get_cmd_func(name)
  return C[name]
end

--- @param name string
--- @return (fun(arglead: string): string[])?
function M._get_cmp_func(name)
  return CP[name]
end

return M
