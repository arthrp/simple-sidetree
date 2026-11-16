local api = vim.api
local config = require("simple-sidetree.config")
local fs = require("simple-sidetree.fs")
local tree = require("simple-sidetree.tree")
local view = require("simple-sidetree.view")
local actions = require("simple-sidetree.actions")

local M = {}

M.actions = actions

local initialized = false
local global_maps = {}

local HIGHLIGHTS = {
  SimpleSidetreeRoot = "Title",
  SimpleSidetreeFolder = "Directory",
  SimpleSidetreeSymlink = "Special",
  SimpleSidetreeIcon = "Comment",
}

local function define_highlights()
  for group, link in pairs(HIGHLIGHTS) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local function tree_visible()
  return view.buf_valid() and #vim.fn.win_findbuf(view.buf) > 0
end

local function create_autocmds()
  local group = api.nvim_create_augroup("SimpleSidetree", { clear = true })

  api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })

  -- Remember the last normal window of each tab: that's where files open.
  api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      view.remember(api.nvim_get_current_win())
    end,
  })

  api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
    group = group,
    callback = function()
      if tree_visible() then
        view.refresh()
      end
    end,
  })

  api.nvim_create_autocmd("DirChanged", {
    group = group,
    pattern = { "global", "tabpage" },
    callback = function()
      if tree.root then
        tree.set_root(vim.fn.getcwd())
        view.render()
      end
    end,
  })

  api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if not config.options.follow_current_file then
        return
      end
      local buf = args.buf
      if buf == view.buf or vim.bo[buf].buftype ~= "" or api.nvim_buf_get_name(buf) == "" then
        return
      end
      vim.schedule(function()
        if not api.nvim_buf_is_valid(buf) or api.nvim_get_current_buf() ~= buf then
          return
        end
        local win = view.get_win()
        if not win then
          return
        end
        local line = tree.reveal(api.nvim_buf_get_name(buf), view.buf)
        if line then
          api.nvim_win_set_cursor(win, { line, 0 })
        end
      end)
    end,
  })

  -- Keep other buffers out of the tree window (e.g. `:e foo` while it has focus).
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      local buf = args.buf
      if buf == view.buf then
        return
      end
      local win = api.nvim_get_current_win()
      if not vim.w[win].simple_sidetree or view.is_float(win) then
        return
      end
      vim.schedule(function()
        if
          api.nvim_win_is_valid(win)
          and api.nvim_buf_is_valid(buf)
          and api.nvim_win_get_buf(win) == buf
        then
          view.restore_tree_in(win, buf)
        end
      end)
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      if not config.options.quit_on_last_window then
        return
      end
      local closed = tonumber(args.match)
      if closed and api.nvim_win_is_valid(closed) and view.is_float(closed) then
        return
      end
      vim.schedule(function()
        if config.options.quit_on_last_window then
          view.maybe_quit()
        end
      end)
    end,
  })
end

---Define highlights and autocmds once (with the current options).
local function init()
  if initialized then
    return
  end
  initialized = true
  define_highlights()
  create_autocmds()
end

local function set_global_keymaps()
  for _, lhs in ipairs(global_maps) do
    pcall(vim.keymap.del, "n", lhs)
  end
  global_maps = {}
  local keymaps = config.options.keymaps or {}
  local function map(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { silent = true, desc = "simple-sidetree: " .. desc })
      global_maps[#global_maps + 1] = lhs
    end
  end
  map(keymaps.switch, M.switch, "switch between tree and main window")
  map(keymaps.toggle, M.toggle, "toggle the tree")
end

---@param opts table|nil see config.lua for all options
function M.setup(opts)
  config.set(opts)
  init()
  set_global_keymaps()
  if view.buf_valid() then
    actions.attach(view.buf)
    view.render()
    for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
      view.restore_width(win)
    end
  end
end

---Open the tree (and focus it).
---@param dir string|nil new root directory
function M.open(dir)
  init()
  if dir and dir ~= "" then
    local path = fs.normalize(dir)
    if not fs.is_dir(path) then
      vim.notify("simple-sidetree: not a directory: " .. dir, vim.log.levels.ERROR)
      return
    end
    tree.set_root(path)
    view.render()
  end
  view.open({ focus = true })
end

function M.close()
  init()
  view.close()
end

function M.toggle()
  init()
  view.toggle({ focus = true })
end

function M.focus()
  init()
  view.focus()
end

---@return boolean
function M.is_open()
  return view.is_open()
end

---Move focus between the tree and the main window, opening the tree if needed.
function M.switch()
  init()
  local tree_win = view.get_win()
  if not tree_win then
    view.open({ focus = true })
    return
  end
  local cur = api.nvim_get_current_win()
  if cur == tree_win then
    local main = view.get_main_win() or view.create_main_win(false)
    api.nvim_set_current_win(main)
  else
    view.remember(cur)
    api.nvim_set_current_win(tree_win)
  end
end

---Reveal the current file in the tree and focus it.
function M.find_file()
  init()
  local buf = api.nvim_get_current_buf()
  if buf == view.buf then
    local main = view.get_main_win()
    if not main then
      return
    end
    buf = api.nvim_win_get_buf(main)
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    view.open({ focus = true })
    return
  end
  local path = fs.normalize(name)
  if not fs.is_within(path, tree.get_root().path) then
    tree.set_root(fs.dirname(path))
  end
  view.open({ focus = true })
  actions.focus_path(path)
end

function M.refresh()
  init()
  view.refresh()
end

return M
