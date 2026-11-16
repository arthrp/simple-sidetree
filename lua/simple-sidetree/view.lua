-- The tree buffer, the side window, and tracking of the main editing window.
local api = vim.api
local config = require("simple-sidetree.config")
local tree = require("simple-sidetree.tree")

local M = {}

M.BUF_NAME = "simple-sidetree://tree"
M.FILETYPE = "simple-sidetree"

---@type integer|nil the single tree buffer, shared by all tabs
M.buf = nil

---@type table<integer, integer> tabpage -> last normal (non-tree) window
M.prev_win = {}

local WIN_OPTS = {
  winfixwidth = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  wrap = false,
  cursorline = true,
  spell = false,
  foldcolumn = "0",
  foldenable = false,
  list = false,
  colorcolumn = "",
}

---@return boolean
function M.buf_valid()
  return M.buf ~= nil and api.nvim_buf_is_valid(M.buf)
end

---@return integer buf
function M.ensure_buf()
  if M.buf_valid() then
    return M.buf
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].undolevels = -1
  pcall(api.nvim_buf_set_name, buf, M.BUF_NAME)
  vim.bo[buf].filetype = M.FILETYPE
  M.buf = buf
  require("simple-sidetree.actions").attach(buf)
  tree.render(buf)
  return buf
end

---Re-render the tree buffer if it exists.
function M.render()
  if M.buf_valid() then
    tree.render(M.buf)
  end
end

---Rescan and re-render the tree buffer if it exists.
function M.refresh()
  if M.buf_valid() then
    tree.refresh(M.buf)
  end
end

---@param win integer
---@return boolean
function M.is_float(win)
  return api.nvim_win_get_config(win).relative ~= ""
end

---@param win integer|nil
---@return boolean
function M.is_tree_win(win)
  return win ~= nil
    and api.nvim_win_is_valid(win)
    and M.buf_valid()
    and api.nvim_win_get_buf(win) == M.buf
end

---The tree window of a tabpage (default: current tabpage), if any.
---@param tab integer|nil
---@return integer|nil
function M.get_win(tab)
  if not M.buf_valid() then
    return nil
  end
  tab = tab or api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(M.buf)) do
    if api.nvim_win_get_tabpage(win) == tab and not M.is_float(win) then
      return win
    end
  end
end

---@return boolean
function M.is_open()
  return M.get_win() ~= nil
end

---Can `win` act as the main editing window?
---@param win integer|nil
---@return boolean
function M.is_main_candidate(win)
  if not win or not api.nvim_win_is_valid(win) or M.is_float(win) then
    return false
  end
  if vim.w[win].simple_sidetree then
    return false
  end
  return not (M.buf_valid() and api.nvim_win_get_buf(win) == M.buf)
end

---Remember `win` as the main window of its tabpage (if it qualifies).
---@param win integer|nil
function M.remember(win)
  if M.is_main_candidate(win) then
    M.prev_win[api.nvim_win_get_tabpage(win)] = win
  end
end

---The window files should be opened in: the last used normal window of the
---current tabpage, else the first normal window (preferring real file buffers).
---@return integer|nil
function M.get_main_win()
  local tab = api.nvim_get_current_tabpage()
  local last = M.prev_win[tab]
  if M.is_main_candidate(last) and api.nvim_win_get_tabpage(last) == tab then
    return last
  end
  local fallback
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if M.is_main_candidate(win) then
      if vim.bo[api.nvim_win_get_buf(win)].buftype == "" then
        return win
      end
      fallback = fallback or win
    end
  end
  return fallback
end

---Apply the tree's window-local options.
---@param win integer
function M.setup_win(win)
  -- :setlocal semantics, so windows later split off from the tree (or other
  -- buffers shown in it) fall back to the user's global window options.
  api.nvim_win_call(win, function()
    for name, value in pairs(WIN_OPTS) do
      vim.opt_local[name] = value
    end
  end)
  vim.w[win].simple_sidetree = true
end

---@param win integer|nil
function M.restore_width(win)
  win = win or M.get_win()
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_set_width(win, config.options.width)
  end
end

---Create a new main window next to the tree (used when there is none).
---@param scratch boolean|nil wipe the empty buffer once something else replaces it
---@return integer win
function M.create_main_win(scratch)
  local tree_win = M.get_win()
  if tree_win then
    api.nvim_set_current_win(tree_win)
  end
  vim.cmd(config.options.side == "right" and "topleft vnew" or "botright vnew")
  local win = api.nvim_get_current_win()
  if scratch then
    vim.bo[api.nvim_win_get_buf(win)].bufhidden = "wipe"
  end
  M.restore_width(tree_win)
  M.remember(win)
  return win
end

---Open the tree window in the current tabpage.
---@param opts { focus: boolean|nil }|nil
---@return integer win
function M.open(opts)
  opts = opts or {}
  local buf = M.ensure_buf()
  local win = M.get_win()
  if win then
    if opts.focus then
      api.nvim_set_current_win(win)
    end
    return win
  end

  local cur = api.nvim_get_current_win()
  if M.is_float(cur) then
    local main = M.get_main_win()
    if main then
      api.nvim_set_current_win(main)
      cur = main
    end
  end
  M.remember(cur)

  vim.cmd(config.options.side == "right" and "botright vsplit" or "topleft vsplit")
  win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  M.setup_win(win)
  M.restore_width(win)
  tree.refresh(buf)

  if not opts.focus and api.nvim_win_is_valid(cur) then
    api.nvim_set_current_win(cur)
  end
  return win
end

---Close the tree window in the current tabpage.
function M.close()
  local win = M.get_win()
  if not win then
    return
  end
  local normal = 0
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if not M.is_float(w) then
      normal = normal + 1
    end
  end
  local main
  if normal <= 1 then
    -- The tree is the only window: leave an empty window behind.
    main = M.create_main_win(false)
  else
    main = M.get_main_win()
  end
  local was_current = api.nvim_get_current_win() == win
  if api.nvim_win_is_valid(win) then
    api.nvim_win_close(win, true)
  end
  if was_current and main and api.nvim_win_is_valid(main) then
    api.nvim_set_current_win(main)
  end
end

---@param opts { focus: boolean|nil }|nil
function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.open(opts or { focus = true })
  end
end

function M.focus()
  M.open({ focus = true })
end

---Something other than the tree buffer was loaded into tree window `win`:
---put the tree back and show `buf` in the main window instead.
---@param win integer
---@param buf integer
function M.restore_tree_in(win, buf)
  local tree_buf = M.ensure_buf()
  api.nvim_win_set_buf(win, tree_buf)
  M.setup_win(win)
  M.restore_width(win)
  -- A newly created main window gets a placeholder buffer that is wiped as
  -- soon as `buf` replaces it.
  local main = M.get_main_win() or M.create_main_win(true)
  api.nvim_win_set_buf(main, buf)
  api.nvim_set_current_win(main)
end

---Quit if the tree is the last non-floating window of the current tabpage.
function M.maybe_quit()
  local win = M.get_win()
  if not win then
    return
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if w ~= win and not M.is_float(w) then
      return
    end
  end
  local ok, err = pcall(vim.cmd, "quit")
  if not ok then
    -- e.g. modified buffers block quitting: give the user a window back.
    M.create_main_win(false)
    vim.notify("simple-sidetree: " .. tostring(err), vim.log.levels.WARN)
  end
end

return M
