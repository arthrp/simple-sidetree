-- Minimal config for tests and manual tryout:
--   nvim -u tests/minimal_init.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.g.mapleader = " "

require("simple-sidetree").setup()
