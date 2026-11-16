-- Buffer-local actions of the tree buffer.
local api = vim.api
local config = require("simple-sidetree.config")
local fs = require("simple-sidetree.fs")
local tree = require("simple-sidetree.tree")
local view = require("simple-sidetree.view")

local M = {}

M.descriptions = {
  open = "Open file / toggle directory",
  vsplit = "Open file in a vertical split",
  split = "Open file in a horizontal split",
  tabnew = "Open file in a new tab",
  close_dir = "Collapse directory (or its parent)",
  add = "Add file (end with / for a directory)",
  rename = "Rename / move",
  delete = "Delete",
  refresh = "Refresh",
  toggle_hidden = "Toggle dotfiles",
  dir_up = "Root: go up one directory",
  cd = "Root: directory under cursor",
  copy_path = "Copy absolute path",
  close = "Close the tree",
  help = "Show this help",
}

local function notify(msg, level)
  vim.notify("simple-sidetree: " .. msg, level or vim.log.levels.INFO)
end

local function err(msg)
  notify(msg, vim.log.levels.ERROR)
end

---@return SimpleSidetreeNode|nil node
---@return integer|nil lnum
local function current_node()
  local win = view.get_win()
  if not win then
    return nil
  end
  local lnum = api.nvim_win_get_cursor(win)[1]
  return tree.node_at(lnum), lnum
end
M.current_node = current_node

---Reveal `path` in the tree and put the tree cursor on it.
---@param path string
function M.focus_path(path)
  local line = tree.reveal(path, view.buf)
  local win = view.get_win()
  if line and win then
    api.nvim_win_set_cursor(win, { line, 0 })
  end
end

local function pretty(path)
  return vim.fn.fnamemodify(path, ":~")
end

---Open `path` in the main window.
---@param path string
---@param how "edit"|"vsplit"|"split"|"tabnew"
function M.open_file(path, how)
  local main = view.get_main_win()
  local created = false
  if not main then
    main = view.create_main_win(true)
    created = true
  end
  api.nvim_set_current_win(main)
  local cmd = ({ edit = "edit", vsplit = "vsplit", split = "split", tabnew = "tabedit" })[how] or "edit"
  if created and how ~= "tabnew" then
    cmd = "edit" -- the new window is already the split
  end
  local ok, e = pcall(vim.cmd, cmd .. " " .. vim.fn.fnameescape(path))
  if not ok then
    err(tostring(e))
    return
  end
  if how ~= "tabnew" then
    view.remember(api.nvim_get_current_win())
    view.restore_width()
    if config.options.close_on_open then
      view.close()
    end
  end
end

function M.open()
  local node, lnum = current_node()
  if not node then
    return
  end
  if lnum == 1 then
    return M.dir_up()
  end
  if node.is_dir then
    tree.toggle(node)
    view.render()
    return
  end
  M.open_file(node.path, "edit")
end

local function open_with(how)
  return function()
    local node, lnum = current_node()
    if not node or lnum == 1 or node.is_dir then
      return
    end
    M.open_file(node.path, how)
  end
end

M.vsplit = open_with("vsplit")
M.split = open_with("split")
M.tabnew = open_with("tabnew")

function M.close_dir()
  local node, lnum = current_node()
  if not node or lnum == 1 then
    return
  end
  if node.is_dir and node.open then
    tree.collapse(node)
    view.render()
    return
  end
  local parent = node.parent
  if parent and parent ~= tree.root then
    tree.collapse(parent)
    view.render()
    local line = tree.find_line(parent.path)
    local win = view.get_win()
    if line and win then
      api.nvim_win_set_cursor(win, { line, 0 })
    end
  end
end

---The directory new entries go into, based on the node under the cursor.
local function target_dir(node, lnum)
  if not node or lnum == 1 then
    return tree.get_root().path
  end
  if node.is_dir then
    return node.path
  end
  return fs.dirname(node.path)
end

function M.add()
  local node, lnum = current_node()
  local dir = target_dir(node, lnum)
  local default = dir == "/" and "/" or (dir .. "/")
  vim.ui.input({ prompt = "Create (end with / for a directory): ", default = default, completion = "file" }, function(input)
    if not input or input == "" or input == default then
      return
    end
    local is_dir = input:sub(-1) == "/"
    local path = fs.normalize(input)
    local ok, e
    if is_dir then
      if fs.exists(path) then
        ok, e = false, pretty(path) .. " already exists"
      else
        ok, e = fs.mkdir_p(path)
      end
    else
      ok, e = fs.create_file(path)
    end
    if not ok then
      err("could not create " .. pretty(path) .. ": " .. tostring(e))
      return
    end
    tree.refresh(view.buf)
    M.focus_path(path)
  end)
end

---Point loaded buffers under `old` at `new` after a rename.
local function rename_buffers(old, new)
  local renamed = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if buf ~= view.buf and api.nvim_buf_is_valid(buf) then
      local name = api.nvim_buf_get_name(buf)
      if name ~= "" and fs.is_within(name, old) then
        local new_name = new .. name:sub(#old + 1)
        if pcall(api.nvim_buf_set_name, buf, new_name) then
          renamed[buf] = true
          -- :file marks the buffer "not edited"; re-edit unmodified ones so
          -- a later :write doesn't complain that the file exists.
          if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and not vim.bo[buf].modified then
            api.nvim_buf_call(buf, function()
              vim.cmd("silent! edit")
            end)
          end
        end
      end
    end
  end
  -- Setting a buffer name leaves an unlisted alternate buffer with the old name.
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not renamed[buf] and buf ~= view.buf and api.nvim_buf_is_valid(buf) then
      local name = api.nvim_buf_get_name(buf)
      if
        name ~= ""
        and fs.is_within(name, old)
        and not api.nvim_buf_is_loaded(buf)
        and not vim.bo[buf].buflisted
      then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
end

function M.rename()
  local node, lnum = current_node()
  if not node or lnum == 1 then
    return
  end
  local old = node.path
  vim.ui.input({ prompt = "Rename to: ", default = old, completion = "file" }, function(input)
    if not input or input == "" then
      return
    end
    local new = fs.normalize(input)
    if new == old then
      return
    end
    local ok, e = fs.rename(old, new)
    if not ok then
      err("could not rename " .. pretty(old) .. ": " .. tostring(e))
      return
    end
    rename_buffers(old, new)
    tree.refresh(view.buf)
    M.focus_path(new)
  end)
end

---Wipe unmodified buffers of deleted files, keeping their windows open.
---@return integer skipped number of modified buffers left alone
local function cleanup_buffers(path)
  local doomed, skipped = {}, 0
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if buf ~= view.buf and api.nvim_buf_is_valid(buf) then
      local name = api.nvim_buf_get_name(buf)
      if name ~= "" and fs.is_within(name, path) then
        if api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
          skipped = skipped + 1
        else
          doomed[buf] = true
        end
      end
    end
  end
  for buf in pairs(doomed) do
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      api.nvim_win_call(win, function()
        local alt = vim.fn.bufnr("#")
        if alt > 0 and not doomed[alt] and alt ~= view.buf and vim.fn.buflisted(alt) == 1 then
          vim.cmd("buffer " .. alt)
        else
          vim.cmd("enew")
        end
      end)
    end
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  return skipped
end

function M.delete()
  local node, lnum = current_node()
  if not node or lnum == 1 then
    return
  end
  local what
  if node.type == "link" then
    what = "symlink"
  elseif node.is_dir then
    what = "directory (and everything in it)"
  else
    what = "file"
  end
  local choice = vim.fn.confirm(("Delete %s %s?"):format(what, pretty(node.path)), "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  local ok, e = fs.remove(node.path)
  if not ok then
    err(tostring(e))
    return
  end
  local skipped = cleanup_buffers(node.path)
  if skipped > 0 then
    notify(("%d modified buffer(s) of deleted files were kept"):format(skipped), vim.log.levels.WARN)
  end
  tree.refresh(view.buf)
end

function M.refresh()
  tree.refresh(view.buf)
end

function M.toggle_hidden()
  config.options.show_hidden = not config.options.show_hidden
  tree.refresh(view.buf)
end

function M.dir_up()
  local root = tree.get_root()
  local parent = fs.dirname(root.path)
  if parent == root.path then
    return
  end
  local old = root.path
  tree.set_root(parent)
  M.focus_path(old)
end

function M.cd()
  local node, lnum = current_node()
  if not node or lnum == 1 then
    return
  end
  local dir = node.is_dir and node.path or fs.dirname(node.path)
  tree.set_root(dir)
  view.render()
  local win = view.get_win()
  if win then
    api.nvim_win_set_cursor(win, { 1, 0 })
  end
end

function M.copy_path()
  local node = current_node()
  if not node then
    return
  end
  vim.fn.setreg('"', node.path)
  pcall(vim.fn.setreg, "+", node.path)
  notify("copied " .. node.path)
end

function M.close()
  view.close()
end

function M.help()
  local entries = {}
  local width = 0
  for lhs, action in pairs(config.options.mappings) do
    if action then
      local desc = type(action) == "function" and "(custom)" or (M.descriptions[action] or action)
      entries[#entries + 1] = { lhs, desc }
      width = math.max(width, #lhs)
    end
  end
  table.sort(entries, function(a, b)
    return a[1]:lower() < b[1]:lower()
  end)
  local lines = {}
  for _, e in ipairs(entries) do
    lines[#lines + 1] = (" %-" .. width .. "s  %s "):format(e[1], e[2])
  end
  local max = 0
  for _, l in ipairs(lines) do
    max = math.max(max, vim.fn.strdisplaywidth(l))
  end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local height = math.min(#lines, vim.o.lines - 4)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = max,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - max) / 2),
    style = "minimal",
    border = "rounded",
    title = " simple-sidetree ",
    title_pos = "center",
  })
  for i = 1, #lines do
    pcall(api.nvim_buf_set_extmark, buf, tree.ns, i - 1, 1, { end_col = 1 + width, hl_group = "Special" })
  end
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
  end
  api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, { buffer = buf, once = true, callback = close })
  return win
end

local attached = {}

---Install the buffer-local mappings on the tree buffer.
---@param buf integer
function M.attach(buf)
  for _, lhs in ipairs(attached[buf] or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  local keys = {}
  for lhs, action in pairs(config.options.mappings or {}) do
    local fn, desc
    if type(action) == "function" then
      fn = function()
        action(current_node())
      end
      desc = "simple-sidetree: custom"
    elseif type(action) == "string" and type(M[action]) == "function" then
      fn = M[action]
      desc = "simple-sidetree: " .. (M.descriptions[action] or action)
    elseif action then
      notify("unknown action '" .. tostring(action) .. "' for " .. lhs, vim.log.levels.WARN)
    end
    if fn then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
      keys[#keys + 1] = lhs
    end
  end
  attached[buf] = keys
end

return M
