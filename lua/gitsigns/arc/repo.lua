local async = require('gitsigns.async')
local arc_command = require('gitsigns.arc.cmd')
local log = require('gitsigns.debug.log')
local util = require('gitsigns.util')
local Path = util.Path

--- @class Gitsigns.ArcRepo
--- @field toplevel string
--- @field gitdir string       Path to .arc dir (used as "gitdir" for watcher compatibility)
--- @field commondir string    Same as gitdir for arc
--- @field abbrev_head string  Current branch name
--- @field head_oid? string    HEAD commit hash
--- @field username string     Arc user login
--- @field detached boolean
--- @field vcs_type 'arc'
--- @field private _lock Gitsigns.async.Semaphore
--- @field private _watcher? Gitsigns.Repo.Watcher
local M = {}
M.__index = M

M.vcs_type = 'arc'

--- Read the full contents of a small file, or nil on failure.
--- @param path string
--- @return string?
local function read_file(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local content = f:read('*a')
  f:close()
  return content
end

--- Parse arc's text-protobuf ref file (.arc/HEAD, .arc/refs/heads/<branch>).
--- Returns (symbolic, id) — at most one is non-nil.
--- @param content string
--- @return string? symbolic Branch name (when HEAD points to a branch)
--- @return string? id       Commit hash (when detached or reading a branch ref)
local function parse_arc_ref(content)
  local symbolic = content:match('Symbolic:%s*"([^"]*)"')
  local id = content:match('Id:%s*"([^"]*)"')
  return symbolic, id
end

--- Synchronously read .arc/HEAD and return the branch name (or short hash).
--- Mirrors git's read_head + get_abbrev_head pattern.
--- @param gitdir string Path to .arc directory
--- @return string? abbrev_head
--- @return boolean detached
local function read_arc_head(gitdir)
  local content = read_file(Path.join(gitdir, 'HEAD'))
  if not content then
    return nil, false
  end
  local symbolic, id = parse_arc_ref(content)
  if symbolic and symbolic ~= '' then
    return symbolic, false
  end
  if id and id ~= '' then
    return id:sub(1, 7), true
  end
  return nil, false
end

--- Synchronously resolve the HEAD commit hash from arc ref files.
--- If HEAD is symbolic (on a branch), reads .arc/refs/heads/<branch>.
--- @param gitdir string
--- @return string? oid
local function get_arc_head_oid(gitdir)
  local content = read_file(Path.join(gitdir, 'HEAD'))
  if not content then
    return nil
  end
  local symbolic, id = parse_arc_ref(content)
  if id and id ~= '' then
    return id
  end
  if symbolic and symbolic ~= '' then
    local ref_content = read_file(Path.join(gitdir, 'refs', 'heads', symbolic))
    if ref_content then
      local _, ref_id = parse_arc_ref(ref_content)
      return ref_id
    end
  end
  return nil
end

--- Walk up from dir looking for .arcadia.root, return containing directory.
--- @param dir string
--- @return string? toplevel
local function find_arcadia_root(dir)
  if not dir or dir == '' then
    return
  end
  local found = vim.fs.find('.arcadia.root', {
    upward = true,
    path = dir,
    type = 'file',
  })
  if found and found[1] then
    return vim.fs.dirname(found[1])
  end
end

--- @type table<string, Gitsigns.ArcRepo?>
local repo_cache = setmetatable({}, { __mode = 'v' })

local sem = async.semaphore(1)

--- Fetch full repo info via `arc info --json`. Used only for initial repo
--- discovery (to validate the repo and obtain the username).
--- @async
--- @param toplevel string
--- @return {abbrev_head:string, head_oid:string, username:string, detached:boolean}? info
--- @return string? err
local function fetch_arc_info(toplevel)
  local stdout, stderr, code = arc_command({ 'info', '--json' }, {
    cwd = toplevel,
    ignore_error = true,
  })

  if code ~= 0 then
    return nil, stderr or 'arc info failed'
  end

  local info_str = table.concat(stdout, '\n')
  local ok, arc_info = pcall(vim.json.decode, info_str)
  if not ok or type(arc_info) ~= 'table' then
    return nil, 'failed to parse arc info output'
  end

  local abbrev_head = arc_info.branch or ''
  local detached = abbrev_head == ''
  if detached and arc_info.hash then
    abbrev_head = arc_info.hash:sub(1, 7)
  end

  return {
    abbrev_head = abbrev_head,
    head_oid = arc_info.hash or '',
    username = arc_info.user_login or arc_info.author or '',
    detached = detached,
  }
end

--- @async
--- @param cwd? string
--- @return Gitsigns.ArcRepo? repo
--- @return string? err
function M.get(cwd)
  return sem:with(function()
    local dir = cwd or vim.fn.getcwd()

    local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated
    -- Resolve symlinks so cache keys are stable
    dir = uv.fs_realpath(dir) or dir

    local toplevel = find_arcadia_root(dir)
    if not toplevel then
      return nil, 'not in arc repository'
    end

    local gitdir = Path.join(toplevel, '.arc')

    local cached = repo_cache[toplevel]
    if cached then
      -- Fast path: read HEAD from disk instead of spawning `arc info`.
      local abbrev_head, detached = read_arc_head(gitdir)
      if abbrev_head then
        cached.abbrev_head = abbrev_head
        cached.detached = detached
      end
      cached.head_oid = get_arc_head_oid(gitdir) or cached.head_oid
      return cached
    end

    -- First time: run `arc info --json` to validate repo and get username.
    local head_info, err = fetch_arc_info(toplevel)
    if not head_info then
      return nil, err
    end

    local repo = M._new(toplevel, head_info)
    repo_cache[toplevel] = repo
    return repo
  end)
end

--- @param toplevel string
--- @param head_info {abbrev_head:string, head_oid:string, username:string}
--- @return Gitsigns.ArcRepo
function M._new(toplevel, head_info)
  --- @type Gitsigns.ArcRepo
  local self = setmetatable({}, M)
  self.toplevel = toplevel
  self.gitdir = Path.join(toplevel, '.arc')
  self.commondir = self.gitdir
  self.abbrev_head = head_info.abbrev_head
  self.head_oid = head_info.head_oid
  self.username = head_info.username
  self.detached = head_info.detached or false
  self._lock = async.semaphore(1)

  -- Set up watcher on .arc dir (same mechanism as git watcher on .git).
  -- The on_update callback reads .arc/HEAD synchronously from disk, just
  -- like the git watcher reads .git/HEAD — no subprocess needed.
  local config = require('gitsigns.config').config
  if config.watch_gitdir.enable and Path.is_dir(self.gitdir) then
    local Watcher = require('gitsigns.git.repo.watcher')
    self._watcher = Watcher.new(self.gitdir)
    self._watcher:on_update(function()
      self.head_oid = get_arc_head_oid(self.gitdir)
      local abbrev_head, detached = read_arc_head(self.gitdir)
      abbrev_head = abbrev_head or ''
      if self.abbrev_head ~= abbrev_head then
        self.abbrev_head = abbrev_head
        self.detached = detached
        log.dprintf('HEAD changed, updating abbrev_head to %s', self.abbrev_head)
      end
    end)
  end

  return self
end

--- Run arc command from the repository root.
--- @async
--- @param args table
--- @param spec? Gitsigns.Git.JobSpec
--- @return string[] stdout
--- @return string? stderr
--- @return integer code
function M:command(args, spec)
  spec = spec or {}
  spec.cwd = self.toplevel
  return arc_command(args, spec)
end

--- @param callback fun()
--- @return fun() deregister
function M:on_update(callback)
  assert(self._watcher, 'Watcher not initialized')
  return self._watcher:on_update(callback)
end

--- @return boolean
function M:has_watcher()
  return self._watcher ~= nil
end

--- @async
--- @generic R
--- @param fn async fun(): R...
--- @return R...
function M:lock(fn)
  return self._lock:with(fn)
end

--- Get file content by arc object reference (e.g. "HEAD:path" or ":0:path").
--- @async
--- @param object string
--- @param encoding? string
--- @return string[] stdout, string? stderr
function M:get_show_text(object, encoding)
  local stdout, stderr = self:command(
    { 'show', object },
    { text = false, ignore_error = true }
  )

  if encoding and encoding ~= 'utf-8' then
    for i, l in ipairs(stdout) do
      stdout[i] = vim.iconv(l, encoding, 'utf-8')
    end
  end

  return stdout, stderr
end

--- @async
--- @param revision string
--- @param relpath string
--- @param encoding? string
--- @return string[] stdout, string? stderr
function M:get_show_text_at_revision(revision, relpath, encoding)
  return self:get_show_text(revision .. ':' .. relpath, encoding)
end

--- Compute relpath from an absolute file path.
--- @param file string Absolute path
--- @return string? relpath
--- @return string? err
function M:_relpath(file)
  local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated
  local real_file = uv.fs_realpath(file) or file
  local real_top = uv.fs_realpath(self.toplevel) or self.toplevel

  if vim.startswith(real_file, real_top .. '/') then
    return real_file:sub(#real_top + 2)
  end

  -- Try without realpath in case of VFS
  if vim.startswith(file, self.toplevel .. '/') then
    return file:sub(#self.toplevel + 2)
  end

  return nil, ('file %s is not under %s'):format(file, self.toplevel)
end

--- Get file tracking info (arc equivalent of git ls-files).
--- @async
--- @param file string Absolute path
--- @param revision? string
--- @return Gitsigns.Repo.LsFiles.Result? info
--- @return string? err
function M:file_info(file, revision)
  local relpath, err = self:_relpath(file)
  if not relpath then
    return nil, err
  end

  -- Revision from tree (not index): check the file exists at that revision
  if revision and not vim.startswith(revision, ':') then
    local _, stderr, code = self:command(
      { 'show', '--quiet', revision .. ':' .. relpath },
      { ignore_error = true }
    )
    if code ~= 0 then
      log.dprintf('arc file_info: %s not found at %s: %s', relpath, revision, stderr)
      return nil, ('file not found at revision %s'):format(revision)
    end
    return {
      relpath = relpath,
      -- Encode the revision+path so get_show_text can fetch it directly
      object_name = revision .. ':' .. relpath,
      mode_bits = '100644',
    }
  end

  -- Index check: arc ls-files --cached
  local stdout, _, code = self:command(
    { 'ls-files', '--cached', relpath },
    { ignore_error = true }
  )

  if code ~= 0 then
    -- arc not available or command failed; treat as untracked
    return { relpath = relpath }
  end

  local tracked = #stdout > 0 and stdout[1] ~= ''
  if not tracked then
    return { relpath = relpath }  -- untracked: object_name = nil
  end

  -- Use ":0:<relpath>" as the object reference for index content.
  -- arc show :0:<relpath> returns the staged version of the file.
  return {
    relpath = relpath,
    object_name = ':0:' .. relpath,
    mode_bits = '100644',
  }
end

--- @async
--- @param base? string
--- @param include_untracked? boolean
--- @return {path:string, oldpath?:string}[]
function M:files_changed(base, include_untracked)
  local ret = {} --- @type {path:string, oldpath?:string}[]

  if base and base ~= ':0' then
    local results, _, code = self:command(
      { 'diff', '--name-status', base },
      { ignore_error = true }
    )
    if code == 0 then
      for _, line in ipairs(results) do
        local parts = vim.split(line, '\t', { plain = true })
        local path = parts[#parts]
        if path and path ~= '' then
          ret[#ret + 1] = { path = path }
        end
      end
    end
    return ret
  end

  local results, _, code = self:command(
    { 'diff', '--name-status' },
    { ignore_error = true }
  )
  if code == 0 then
    for _, line in ipairs(results) do
      local parts = vim.split(line, '\t', { plain = true })
      local status = parts[1]
      local path = parts[2]
      if path and path ~= '' then
        if status and (status:match('^[MAD]')
          or (include_untracked and (status == '?' or status == '??')))
        then
          ret[#ret + 1] = { path = path }
        end
      end
    end
  end

  return ret
end

--- Arc does not have git attributes. Return 'unspecified' for all files.
--- @param _attr string
--- @param files string[]
--- @return table<string, 'set'|'unset'|'unspecified'|string>
function M:check_attr(_attr, files)
  local ret = {} --- @type table<string, string>
  for _, f in ipairs(files) do
    ret[f] = 'unspecified'
  end
  return ret
end

--- Arc rename tracking is not implemented; return empty map.
--- @param _revision? string
--- @param _invert? boolean
--- @return table<string, string>
function M:diff_rename_status(_revision, _invert)
  return {}
end

--- @param _revision string
--- @param _path string
--- @return string?
function M:log_rename_status(_revision, _path)
  return nil
end

return M
