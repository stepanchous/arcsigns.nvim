local log = require('gitsigns.debug.log')
local error_once = require('gitsigns.message').error_once

--- Parse an ISO 8601 date string to a Unix timestamp.
--- Arc outputs dates like "2025-04-17T10:57:20+03:00".
--- @param date_str string
--- @return integer
local function parse_iso8601(date_str)
  local year, month, day, hour, min, sec, tz_sign, tz_h, tz_m =
    date_str:match('^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)([%+%-Z]?)(%d?%d?)%:?(%d?%d?)$')

  if not year then
    return os.time()
  end

  -- Compute Unix timestamp using UTC math.
  -- os.time() interprets the table as local time, so we compensate.
  local local_offset = os.time() - os.time(os.date('!*t') --[[@as osdate]])

  local t = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  }) - local_offset  -- now t is UTC epoch

  -- Apply timezone offset from the date string
  if tz_sign == '+' and tz_h ~= '' then
    t = t - (tonumber(tz_h) * 3600 + tonumber(tz_m or '0') * 60)
  elseif tz_sign == '-' and tz_h ~= '' then
    t = t + (tonumber(tz_h) * 3600 + tonumber(tz_m or '0') * 60)
  end

  return t
end

--- @param file string
--- @return Gitsigns.CommitInfo
local function not_committed(file)
  local time = os.time()
  return {
    sha = string.rep('0', 40),
    abbrev_sha = string.rep('0', 8),
    author = 'Not Committed Yet',
    author_mail = '<not.committed.yet>',
    author_time = time,
    author_tz = '+0000',
    committer = 'Not Committed Yet',
    committer_mail = '<not.committed.yet>',
    committer_time = time,
    committer_tz = '+0000',
    summary = 'Version of ' .. file,
  }
end

local M = {}

--- @param file string
--- @param lnum integer
--- @return Gitsigns.BlameInfo
function M.get_blame_nc(file, lnum)
  return {
    orig_lnum = 0,
    final_lnum = lnum,
    commit = not_committed(file),
    filename = file,
  }
end

--- Convert an arc blame annotation entry to CommitInfo + BlameInfo.
--- @param entry {line:integer, author:string, commit:string, date:string, text:string}
--- @param relpath string
--- @return Gitsigns.CommitInfo commit
--- @return Gitsigns.BlameInfo blame_info
local function entry_to_blame(entry, relpath)
  local sha = entry.commit or string.rep('0', 40)
  local author_time = parse_iso8601(entry.date or '')
  local author = entry.author or 'Unknown'

  --- @type Gitsigns.CommitInfo
  local commit = {
    sha = sha,
    abbrev_sha = sha:sub(1, 8),
    author = author,
    author_mail = '<' .. author .. '>',
    author_time = author_time,
    author_tz = '+0000',
    committer = author,
    committer_mail = '<' .. author .. '>',
    committer_time = author_time,
    committer_tz = '+0000',
    summary = '',  -- not available in arc blame --json output
  }

  --- @type Gitsigns.BlameInfo
  local blame_info = {
    orig_lnum = entry.line,
    final_lnum = entry.line,
    commit = commit,
    filename = relpath,
  }

  return commit, blame_info
end

--- Run arc blame --json and return blame info in the same format as git.blame.run_blame.
--- @async
--- @param obj Gitsigns.GitObj
--- @param contents? string[]   Passed for untracked files; arc blame ignores this
--- @param lnum? integer|[integer, integer]
--- @param _revision? string    Unused: arc blame always blames HEAD
--- @param opts? Gitsigns.BlameOpts
--- @return table<integer, Gitsigns.BlameInfo>
--- @return table<string, Gitsigns.CommitInfo?>
function M.run_blame(obj, contents, lnum, _revision, opts)
  local ret = {} --- @type table<integer, Gitsigns.BlameInfo>
  local commits = {} --- @type table<string, Gitsigns.CommitInfo?>

  local relpath = obj.relpath
  if not relpath then
    return ret, commits
  end

  -- Untracked or repo with no commits
  if not obj.object_name or obj.repo.abbrev_head == '' then
    local commit = not_committed(obj.file)
    for i in ipairs(contents or {}) do
      ret[i] = {
        orig_lnum = 0,
        final_lnum = i,
        commit = commit,
        filename = relpath,
      }
    end
    return ret, commits
  end

  local args = { 'blame', '--json' }

  if opts and opts.ignore_whitespace then
    args[#args + 1] = '-w'
  end

  if lnum then
    local l_start, l_end --- @type integer, integer
    if type(lnum) == 'table' then
      l_start, l_end = lnum[1], lnum[2]
    else
      l_start, l_end = lnum, lnum
    end
    args[#args + 1] = '-L'
    args[#args + 1] = l_start .. ',' .. l_end
  end

  args[#args + 1] = relpath

  local stdout, stderr = obj.repo:command(args, { ignore_error = true })

  if stderr then
    local msg = 'Error running arc-blame: ' .. stderr
    error_once(msg)
    log.eprint(msg)
    return ret, commits
  end

  local json_str = table.concat(stdout, '\n')
  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= 'table' or type(data.annotation) ~= 'table' then
    log.eprintf('Failed to parse arc blame output: %s', json_str:sub(1, 200))
    return ret, commits
  end

  for _, entry in ipairs(data.annotation) do
    local entry_lnum = entry.line
    if type(entry_lnum) ~= 'number' then
      goto continue
    end

    local sha = entry.commit or string.rep('0', 40)
    local commit = commits[sha]
    if not commit then
      local c, b = entry_to_blame(entry, relpath)
      commit = c
      commits[sha] = commit
      ret[entry_lnum] = b
    else
      ret[entry_lnum] = {
        orig_lnum = entry_lnum,
        final_lnum = entry_lnum,
        commit = commit,
        filename = relpath,
      }
    end

    ::continue::
  end

  return ret, commits
end

return M
