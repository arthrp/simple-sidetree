local uv = vim.uv or vim.loop

local M = {}

M.sep = package.config:sub(1, 1)

---Normalize a path: absolute, no trailing separator (except for "/").
---@param path string
---@return string
function M.normalize(path)
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if #path > 1 then
    path = path:gsub("[/\\]+$", "")
  end
  if path == "" then
    path = "/"
  end
  return path
end

---@param ... string
---@return string
function M.join(...)
  local parts = { ... }
  local out = table.concat(parts, "/")
  out = out:gsub("/+", "/")
  return out
end

---@param path string
---@return string
function M.dirname(path)
  local d = vim.fn.fnamemodify(path, ":h")
  return d
end

---@param path string
---@return string
function M.basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

---@param path string
---@return table|nil
function M.stat(path)
  return uv.fs_stat(path)
end

---@param path string
---@return boolean
function M.exists(path)
  return uv.fs_lstat(path) ~= nil
end

---@param path string
---@return boolean
function M.is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---Is `path` equal to `ancestor` or inside it?
---@param path string
---@param ancestor string
---@return boolean
function M.is_within(path, ancestor)
  if path == ancestor then
    return true
  end
  local prefix = ancestor == "/" and "/" or (ancestor .. "/")
  return path:sub(1, #prefix) == prefix
end

---@class SimpleSidetreeEntry
---@field name string
---@field path string
---@field type "file"|"directory"|"link"
---@field is_dir boolean

---List a directory. Directories first, then case-insensitive by name.
---@param dir string
---@param show_hidden boolean
---@return SimpleSidetreeEntry[]
function M.scandir(dir, show_hidden)
  local entries = {}
  local ok, iter = pcall(vim.fs.dir, dir)
  if not ok then
    return entries
  end
  local ok2, err = pcall(function()
    for name, typ in iter do
      if show_hidden or name:sub(1, 1) ~= "." then
        local path = M.join(dir, name)
        local is_dir = typ == "directory"
        local kind = typ == "directory" and "directory" or "file"
        if typ == "link" then
          kind = "link"
          local st = uv.fs_stat(path)
          is_dir = st ~= nil and st.type == "directory"
        elseif typ == nil or typ == "unknown" then
          local st = uv.fs_stat(path)
          is_dir = st ~= nil and st.type == "directory"
          kind = is_dir and "directory" or "file"
        end
        entries[#entries + 1] = { name = name, path = path, type = kind, is_dir = is_dir }
      end
    end
  end)
  if not ok2 then
    vim.notify("simple-sidetree: cannot read " .. dir .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
  table.sort(entries, function(a, b)
    if a.is_dir ~= b.is_dir then
      return a.is_dir
    end
    local la, lb = a.name:lower(), b.name:lower()
    if la ~= lb then
      return la < lb
    end
    return a.name < b.name
  end)
  return entries
end

---Create a directory and all missing parents.
---@param path string
---@return boolean ok
---@return string|nil err
function M.mkdir_p(path)
  if M.is_dir(path) then
    return true
  end
  local ok = vim.fn.mkdir(path, "p")
  if ok == 1 or M.is_dir(path) then
    return true
  end
  return false, "could not create directory " .. path
end

---Create an empty file. Refuses to overwrite an existing file.
---@param path string
---@return boolean ok
---@return string|nil err
function M.create_file(path)
  local ok, err = M.mkdir_p(M.dirname(path))
  if not ok then
    return false, err
  end
  local fd, open_err = uv.fs_open(path, "wx", 420) -- 0644
  if not fd then
    return false, open_err
  end
  uv.fs_close(fd)
  return true
end

---@param from string
---@param to string
---@return boolean ok
---@return string|nil err
function M.rename(from, to)
  if M.exists(to) then
    return false, to .. " already exists"
  end
  local ok, err = M.mkdir_p(M.dirname(to))
  if not ok then
    return false, err
  end
  local res, rename_err = uv.fs_rename(from, to)
  if not res then
    return false, rename_err
  end
  return true
end

---Delete a file, or a directory recursively.
---@param path string
---@return boolean ok
---@return string|nil err
function M.remove(path)
  local lst = uv.fs_lstat(path)
  if not lst then
    return false, path .. " does not exist"
  end
  local flags = lst.type == "directory" and "rf" or ""
  if vim.fn.delete(path, flags) ~= 0 then
    return false, "could not delete " .. path
  end
  return true
end

return M
