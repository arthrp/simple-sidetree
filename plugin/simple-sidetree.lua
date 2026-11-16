if vim.g.loaded_simple_sidetree then
  return
end
vim.g.loaded_simple_sidetree = 1

local function st()
  return require("simple-sidetree")
end

local cmd = vim.api.nvim_create_user_command

cmd("SimpleSidetreeOpen", function(o)
  st().open(o.args ~= "" and o.args or nil)
end, { nargs = "?", complete = "dir", desc = "Open the file tree (optionally at a directory)" })

cmd("SimpleSidetreeClose", function()
  st().close()
end, { desc = "Close the file tree" })

cmd("SimpleSidetreeToggle", function()
  st().toggle()
end, { desc = "Toggle the file tree" })

cmd("SimpleSidetreeFocus", function()
  st().focus()
end, { desc = "Focus the file tree" })

cmd("SimpleSidetreeFindFile", function()
  st().find_file()
end, { desc = "Reveal the current file in the file tree" })

cmd("SimpleSidetreeRefresh", function()
  st().refresh()
end, { desc = "Rescan the file tree" })
