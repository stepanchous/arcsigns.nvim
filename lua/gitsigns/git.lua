local log = require('gitsigns.debug.log')
local async = require('gitsigns.async')
local util = require('gitsigns.util')
local Repo = require('gitsigns.git.repo')
local errors = require('gitsigns.git.errors')

local M = {}

M.Repo = Repo

--- @class Gitsigns.GitObj
--- @field file string
--- @field encoding string
--- @field i_crlf? boolean Object has crlf
--- @field w_crlf? boolean Working copy has crlf
--- @field mode_bits string
---
--- Revision the object is tracking against. Nil for index
--- @field revision? string
---
--- The fixed object name to use. Nil for untracked.
--- @field object_name? string
---
--- The path of the file relative to toplevel. Used to
--- perform git operations. Nil if file does not exist
--- @field relpath? string
---
--- Used for tracking moved files
--- @field orig_relpath? string
---
--- @field repo Gitsigns.Repo
--- @field has_conflicts? boolean
local Obj = {}
Obj.__index = Obj

M.Obj = Obj

--- @async
--- @param revision? string
--- @return string? err
function Obj:change_revision(revision)
  self.revision = util.norm_base(revision)
  return self:refresh()
end

--- @async
--- @param fn async fun()
function Obj:lock(fn)
  return self.repo:lock(fn)
end

--- @async
--- @return string? err
function Obj:refresh()
  local info, err = self.repo:file_info(self.file, self.revision)

  if err then
    log.eprint(err)
  end

  if not info then
    return err
  end

  self.relpath = info.relpath
  self.object_name = info.object_name
  self.mode_bits = info.mode_bits
  self.has_conflicts = info.has_conflicts
  self.i_crlf = info.i_crlf
  self.w_crlf = info.w_crlf
end

function Obj:from_tree()
  return Repo.from_tree(self.revision)
end

--- @async
--- @param revision? string
--- @param relpath? string
--- @return string[] stdout, string? stderr
function Obj:get_show_text(revision, relpath)
  relpath = relpath or self.relpath
  if revision and not relpath then
    log.dprint('no relpath')
    return {}
  end

  if not revision and not self.object_name then
    log.dprint('no revision or object_name')
    return { '' }
  end

  local stdout, stderr
  if revision then
    --- @cast relpath -?
    stdout, stderr = self.repo:get_show_text_at_revision(revision, relpath, self.encoding)
  else
    stdout, stderr = self.repo:get_show_text(assert(self.object_name), self.encoding)
  end

  if not self.i_crlf and self.w_crlf then
    -- Add cr
    -- Do not add cr to the newline at the end of file
    for i = 1, #stdout - 1 do
      stdout[i] = stdout[i] .. '\r'
    end
  end

  return stdout, stderr
end

--- @async
--- @param contents? string[]
--- @param lnum? integer|[integer, integer]
--- @param revision? string
--- @param opts? Gitsigns.BlameOpts
--- @return table<integer,Gitsigns.BlameInfo?>
--- @return table<string,Gitsigns.CommitInfo?>
function Obj:run_blame(contents, lnum, revision, opts)
  if self.repo.vcs_type == 'arc' then
    return require('gitsigns.arc.blame').run_blame(self, contents, lnum, revision, opts)
  end
  return require('gitsigns.git.blame').run_blame(self, contents, lnum, revision, opts)
end

--- @async
--- @param file string Absolute path or relative to toplevel
--- @param revision string?
--- @param encoding string
--- @param gitdir string?
--- @param toplevel string?
--- @return Gitsigns.GitObj?
function Obj.new(file, revision, encoding, gitdir, toplevel)
  local cwd = toplevel
  if not cwd and util.Path.is_abs(file) then
    cwd = vim.fn.fnamemodify(file, ':h')
  end

  local repo, err = Repo.get(cwd, gitdir, toplevel)
  if not repo then
    log.dprint('Not in git repo')
    if err and not err:match(errors.e.not_in_git) and not err:match(errors.e.worktree) then
      log.eprint(err)
    end
    return
  end

  if vim.startswith(vim.fn.fnamemodify(file, ':p'), vim.fn.fnamemodify(repo.gitdir, ':p')) then
    -- Normally this check would be caught (unintended) in the above
    -- block, as gitdir resolution will fail if `file` is inside a gitdir.
    -- If gitdir is explicitly passed (or set in the env with GIT_DIR)
    -- then resolution will succeed, but we still don't want to
    -- attach if `file` is inside the gitdir.
    log.dprint('In gitdir')
    return
  end

  -- When passing gitdir and toplevel, suppress stderr when resolving the file
  local silent = gitdir ~= nil and toplevel ~= nil

  revision = util.norm_base(revision)

  local info, err2 = repo:file_info(file, revision)

  if err2 and not silent then
    log.eprint(err2)
  end

  if not info then
    return
  end

  if info.relpath then
    file = util.Path.join(repo.toplevel, info.relpath)
  end

  local self = setmetatable({}, Obj)
  self.repo = repo
  self.file = util.cygpath(file, 'unix')
  self.revision = revision
  self.encoding = encoding

  self.relpath = info.relpath
  self.object_name = info.object_name
  self.mode_bits = info.mode_bits
  self.has_conflicts = info.has_conflicts
  self.i_crlf = info.i_crlf
  self.w_crlf = info.w_crlf

  return self
end

return M
