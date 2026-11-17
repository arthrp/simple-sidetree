local M = {}

---@class SimpleSidetreeConfig
M.defaults = {
  side = "left", -- "left" | "right"
  width = 30,
  show_hidden = false, -- show dotfiles
  indent = 2,
  use_devicons = true, -- only used if nvim-web-devicons is installed
  icons = {
    folder_closed = "▸",
    folder_open = "▾",
    file = " ",
  },
  close_on_open = false, -- close the tree after opening a file
  follow_current_file = false, -- reveal the current buffer in the tree on BufEnter
  quit_on_last_window = true, -- quit Neovim if the tree is the last window in the tab
  -- Global (normal mode) keymaps. Set a value to false to disable it.
  keymaps = {
    switch = "<leader><Tab>",
    toggle = false,
  },
  -- Buffer-local keymaps inside the tree. Set a value to false to disable it.
  mappings = {
    ["<CR>"] = "open",
    ["o"] = "open",
    ["<2-LeftMouse>"] = "open",
    ["v"] = "vsplit",
    ["s"] = "split",
    ["t"] = "tabnew",
    ["<BS>"] = "close_dir",
    ["a"] = "add",
    ["r"] = "rename",
    ["d"] = "delete",
    ["R"] = "refresh",
    ["H"] = "toggle_hidden",
    ["-"] = "dir_up",
    ["C"] = "cd",
    ["Y"] = "copy_path",
    ["c"] = "close",
    ["g?"] = "help",
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if M.options.side ~= "left" and M.options.side ~= "right" then
    vim.notify("simple-sidetree: invalid side '" .. tostring(M.options.side) .. "', using 'left'", vim.log.levels.WARN)
    M.options.side = "left"
  end
  return M.options
end

return M
