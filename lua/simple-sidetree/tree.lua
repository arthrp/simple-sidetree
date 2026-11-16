-- Tree model and rendering. Has no dependency on the view: callers pass the
-- buffer to render into.
local api = vim.api
local config = require("simple-sidetree.config")
local fs = require("simple-sidetree.fs")

local M = {}

M.ns = api.nvim_create_namespace("simple_sidetree")

---@class SimpleSidetreeNode
---@field path string
---@field name string
---@field type "file"|"directory"|"link"
---@field is_dir boolean
---@field open boolean
---@field children SimpleSidetreeNode[]|nil nil until first expanded
---@field parent SimpleSidetreeNode|nil
---@field depth integer|nil set while rendering
---@field stale boolean|nil children need a rescan

---@type SimpleSidetreeNode|nil
M.root = nil

---@type table<integer, SimpleSidetreeNode> line number -> node (line 1 is the root header)
M.line_nodes = {}

local function new_node(entry, parent)
  return {
    path = entry.path,
    name = entry.name,
    type = entry.type,
    is_dir = entry.is_dir,
    open = false,
    children = nil,
    parent = parent,
  }
end

local function make_root(path)
  return {
    path = path,
    name = fs.basename(path),
    type = "directory",
    is_dir = true,
    open = true,
    children = nil,
    parent = nil,
  }
end

---@return SimpleSidetreeNode
function M.get_root()
  if not M.root then
    M.root = make_root(fs.normalize(vim.fn.getcwd()))
  end
  return M.root
end

---(Re)scan a directory node. Existing child nodes with the same path are kept,
---so their open state and loaded children survive.
---@param node SimpleSidetreeNode
function M.load_children(node)
  local old = {}
  for _, child in ipairs(node.children or {}) do
    old[child.path] = child
  end
  local children = {}
  for _, entry in ipairs(fs.scandir(node.path, config.options.show_hidden)) do
    local child = old[entry.path]
    if child and child.is_dir == entry.is_dir then
      child.name = entry.name
      child.type = entry.type
    else
      child = new_node(entry, node)
    end
    child.parent = node
    children[#children + 1] = child
  end
  node.children = children
  node.stale = nil
end

---@param node SimpleSidetreeNode
function M.ensure_children(node)
  if node.is_dir and (node.children == nil or node.stale) then
    M.load_children(node)
  end
end

---@param node SimpleSidetreeNode
function M.expand(node)
  if not node.is_dir then
    return
  end
  M.ensure_children(node)
  node.open = true
end

---@param node SimpleSidetreeNode
function M.collapse(node)
  if node.is_dir and node ~= M.root then
    node.open = false
  end
end

---@param node SimpleSidetreeNode
function M.toggle(node)
  if node.open then
    M.collapse(node)
  else
    M.expand(node)
  end
end

local function mark_stale(node)
  if node.children then
    node.stale = true
    for _, child in ipairs(node.children) do
      mark_stale(child)
    end
  end
end

---Split the part of `path` below `root` into its components.
local function relative_parts(path, root)
  local rel = path:sub(#root + (root == "/" and 1 or 2))
  local parts = {}
  for part in rel:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function find_child(node, path)
  for _, child in ipairs(node.children or {}) do
    if child.path == path then
      return child
    end
  end
end

---Walk from the root towards `path`.
---@param path string normalized absolute path
---@param expand boolean expand (and scan) every ancestor on the way
---@return SimpleSidetreeNode|nil deepest node reached
local function walk(path, expand)
  local root = M.get_root()
  if not fs.is_within(path, root.path) then
    return nil
  end
  local node = root
  local cur = root.path
  for _, part in ipairs(relative_parts(path, root.path)) do
    if expand then
      M.expand(node)
    elseif not node.children then
      break
    end
    cur = fs.join(cur, part)
    local child = find_child(node, cur)
    if not child then
      break
    end
    node = child
  end
  return node
end

---Find an already loaded node by path.
---@param path string
---@return SimpleSidetreeNode|nil
function M.find_node(path)
  path = fs.normalize(path)
  local node = walk(path, false)
  if node and node.path == path then
    return node
  end
end

---Change the root directory. Reuses the loaded subtree when the new root is
---inside the old one, and keeps the old root (expanded) when moving up.
---@param path string
function M.set_root(path)
  path = fs.normalize(path)
  local old = M.root
  if old and old.path == path then
    return
  end
  if old and fs.is_within(path, old.path) then
    local node = M.find_node(path)
    if node and node.is_dir then
      node.parent = nil
      node.open = true
      M.root = node
      return
    end
  end
  local new_root = make_root(path)
  M.root = new_root
  if old and fs.is_within(old.path, path) then
    local node = new_root
    local cur = path
    local parts = relative_parts(old.path, path)
    for i, part in ipairs(parts) do
      M.expand(node)
      cur = fs.join(cur, part)
      local child = find_child(node, cur)
      if not child then
        break
      end
      if i == #parts then
        for idx, c in ipairs(node.children) do
          if c == child then
            old.parent = node
            old.name = child.name
            old.type = child.type
            old.open = true
            node.children[idx] = old
            break
          end
        end
      else
        child.open = true
        node = child
      end
    end
  end
end

local devicons_mod
local function get_devicons()
  if not config.options.use_devicons then
    return nil
  end
  if devicons_mod == nil then
    local ok, mod = pcall(require, "nvim-web-devicons")
    devicons_mod = ok and mod or false
  end
  return devicons_mod or nil
end

local function flatten(node, depth, out)
  M.ensure_children(node)
  for _, child in ipairs(node.children or {}) do
    child.depth = depth
    out[#out + 1] = child
    if child.is_dir and child.open then
      flatten(child, depth + 1, out)
    end
  end
end

---Build the lines, highlights and line -> node map without touching a buffer.
---@return string[] lines
---@return table[] highlights { row, start_col, end_col, group }
---@return table<integer, SimpleSidetreeNode> line_nodes
function M.build()
  local opts = config.options
  local icons = opts.icons
  local root = M.get_root()
  local nodes = {}
  flatten(root, 0, nodes)

  local devicons = get_devicons()
  local lines, hls, line_nodes = {}, {}, {}

  local header = vim.fn.fnamemodify(root.path, ":~")
  lines[1] = header
  line_nodes[1] = root
  hls[#hls + 1] = { 0, 0, #header, "SimpleSidetreeRoot" }

  for i, node in ipairs(nodes) do
    local row = i -- 0-based row of this node (header is row 0)
    local line = string.rep(" ", node.depth * opts.indent)

    local icon
    if node.is_dir then
      icon = node.open and icons.folder_open or icons.folder_closed
    else
      icon = icons.file
    end
    hls[#hls + 1] = { row, #line, #line + #icon, "SimpleSidetreeIcon" }
    line = line .. icon .. " "

    if devicons and not node.is_dir then
      local ext = node.name:match("%.([^.]+)$")
      local dicon, dhl = devicons.get_icon(node.name, ext, { default = true })
      if dicon then
        if dhl then
          hls[#hls + 1] = { row, #line, #line + #dicon, dhl }
        end
        line = line .. dicon .. " "
      end
    end

    local group
    if node.type == "link" then
      group = "SimpleSidetreeSymlink"
    elseif node.is_dir then
      group = "SimpleSidetreeFolder"
    end
    if group then
      hls[#hls + 1] = { row, #line, #line + #node.name, group }
    end
    line = line .. node.name

    lines[#lines + 1] = line
    line_nodes[row + 1] = node
  end

  return lines, hls, line_nodes
end

---@param path string
---@return integer|nil
function M.find_line(path)
  for lnum, node in pairs(M.line_nodes) do
    if node.path == path then
      return lnum
    end
  end
end

---@param lnum integer
---@return SimpleSidetreeNode|nil
function M.node_at(lnum)
  return M.line_nodes[lnum]
end

---Render the tree into `buf`, keeping every tree window's cursor on the same path.
---@param buf integer|nil
function M.render(buf)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end

  local saved = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local cursor = api.nvim_win_get_cursor(win)
    local node = M.line_nodes[cursor[1]]
    saved[win] = { path = node and node.path, lnum = cursor[1], col = cursor[2] }
  end

  local lines, hls, line_nodes = M.build()
  M.line_nodes = line_nodes

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, hl in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, buf, M.ns, hl[1], hl[2], { end_col = hl[3], hl_group = hl[4] })
  end

  for win, s in pairs(saved) do
    if api.nvim_win_is_valid(win) then
      local lnum = (s.path and M.find_line(s.path)) or math.min(s.lnum, #lines)
      pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
    end
  end
end

---Rescan all loaded directories and re-render.
---@param buf integer|nil
function M.refresh(buf)
  mark_stale(M.get_root())
  M.render(buf)
end

---Expand every ancestor of `path`, re-render, and return its line (or nil).
---@param path string
---@param buf integer|nil
---@return integer|nil
function M.reveal(path, buf)
  path = fs.normalize(path)
  local node = walk(path, true)
  M.render(buf)
  if node and node.path == path then
    return M.find_line(path)
  end
end

return M
