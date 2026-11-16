# simple-sidetree

A small sidebar file manager for Neovim, in the spirit of nvim-tree: a file tree
in its own split next to your editing window, and one key (`<leader><Tab>` by
default) to jump between the two.

- Neovim ≥ 0.9, no dependencies (uses [nvim-web-devicons] for file icons if it is installed)
- Browse, expand/collapse, open in the main window / splits / tabs
- Add, rename/move and delete files and directories, copy paths
- One tree window per tab, all sharing the same tree state

Out of scope by design: git status, file watchers, hijacking netrw.

[nvim-web-devicons]: https://github.com/nvim-tree/nvim-web-devicons

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim), using the local checkout. The
spec is a table, so it has to go where lazy.nvim expects specs, not on its own
in `init.lua`. Either return it from a file in your plugins directory, e.g.
`~/.config/nvim/lua/plugins/simple-sidetree.lua`:

```lua
return {
  dir = "path/to/simple-sidetree",
  config = function()
    require("simple-sidetree").setup({})
  end,
}
```

or put it in the list you pass to `require("lazy").setup()`:

```lua
vim.g.mapleader = " " -- before lazy.nvim loads plugins

require("lazy").setup({
  {
    dir = "path/to/simple-sidetree",
    config = function()
      require("simple-sidetree").setup({})
    end,
  },
  -- your other plugins...
})
```

Without a plugin manager, put (or symlink) the directory into a `pack/*/opt`
directory on your `packpath` and run:

```lua
vim.cmd.packadd("simple-sidetree")
require("simple-sidetree").setup({})
```

> Set `vim.g.mapleader` **before** calling `setup()`: `<leader>` in
> `keymaps.switch` is expanded when the mapping is created.

## Configuration

`setup()` with all defaults:

```lua
require("simple-sidetree").setup({
  side = "left",               -- "left" | "right"
  width = 30,
  show_hidden = false,         -- show dotfiles (toggle with H)
  indent = 2,
  use_devicons = true,         -- only used if nvim-web-devicons is installed
  icons = { folder_closed = "▸", folder_open = "▾", file = " " },
  close_on_open = false,       -- close the tree after opening a file
  follow_current_file = false, -- move the tree cursor to the current buffer's file
  quit_on_last_window = true,  -- quit if the tree is the last window in the tab
  -- Global normal-mode keymaps; false disables one.
  keymaps = {
    switch = "<leader><Tab>",  -- tree <-> main window (opens the tree if needed)
    toggle = false,            -- e.g. "<leader>e"
  },
  -- Buffer-local keymaps in the tree; false disables one.
  mappings = {
    ["<CR>"] = "open", o = "open", ["<2-LeftMouse>"] = "open",
    v = "vsplit", s = "split", t = "tabnew",
    ["<BS>"] = "close_dir",
    a = "add", r = "rename", d = "delete",
    R = "refresh", H = "toggle_hidden",
    ["-"] = "dir_up", C = "cd",
    Y = "copy_path", q = "close", ["g?"] = "help",
  },
})
```

`mappings` values are merged with the defaults. A value can also be a function,
which is called with the node under the cursor (`{ path, name, type, is_dir, ... }`,
or `nil` when there is none):

```lua
require("simple-sidetree").setup({
  mappings = {
    d = false,                       -- disable
    ["<C-x>"] = "delete",            -- rebind an action
    gx = function(node)              -- custom action (vim.ui.open needs Neovim 0.10)
      if node then vim.ui.open(node.path) end
    end,
  },
})
```

Calling `setup()` is optional for the commands: without it the defaults are
used, but the global `switch`/`toggle` keymaps are only created by `setup()`.

## Keymaps in the tree

| Key                         | Action          | Description                                                     |
| --------------------------- | --------------- | --------------------------------------------------------------- |
| `<CR>`, `o`, `<2-LeftMouse>`| `open`          | Open file in the main window / toggle directory / on the header line: go up |
| `v`                         | `vsplit`        | Open file in a vertical split of the main window                |
| `s`                         | `split`         | Open file in a horizontal split of the main window              |
| `t`                         | `tabnew`        | Open file in a new tab                                          |
| `<BS>`                      | `close_dir`     | Collapse the directory, or the parent of the entry under the cursor |
| `a`                         | `add`           | Create a file; end the name with `/` to create a directory. Missing parent directories are created, existing files are never overwritten |
| `r`                         | `rename`        | Rename / move (full path prompt). Open buffers follow the rename |
| `d`                         | `delete`        | Delete (asks first; directories recursively, symlinks only remove the link). Unmodified buffers of deleted files are wiped, modified ones are kept |
| `R`                         | `refresh`       | Rescan                                                          |
| `H`                         | `toggle_hidden` | Show / hide dotfiles                                            |
| `-`                         | `dir_up`        | Make the parent directory the root                              |
| `C`                         | `cd`            | Make the directory under the cursor the root                    |
| `Y`                         | `copy_path`     | Copy the absolute path to the `+` and `"` registers             |
| `q`                         | `close`         | Close the tree window                                           |
| `g?`                        | `help`          | Show the active mappings                                        |

The root changes with the tree only; Neovim's working directory is not touched.
The other way round, `:cd` / `:tcd` do change the tree's root.

## Switching windows

`keymaps.switch` (`<leader><Tab>`) does:

1. tree not open in this tab → open it and focus it;
2. in the tree → go back to the main window (the last normal window you used in
   this tab; one is created if there is none);
3. anywhere else → remember this window as the main window and focus the tree.

Files opened from the tree always go to that main window. If something else is
loaded into the tree window (say, `:e foo` while the tree has focus), the tree
is put back and the file is shown in the main window.

## Commands

| Command                         | Description                                          |
| ------------------------------- | ---------------------------------------------------- |
| `:SimpleSidetreeOpen [dir]`     | Open and focus the tree, optionally rooted at `dir`  |
| `:SimpleSidetreeClose`          | Close the tree in this tab                           |
| `:SimpleSidetreeToggle`         | Toggle the tree                                      |
| `:SimpleSidetreeFocus`          | Focus the tree (opening it if needed)                |
| `:SimpleSidetreeFindFile`       | Reveal the current file in the tree and focus it (re-roots if the file is outside the root) |
| `:SimpleSidetreeRefresh`        | Rescan the tree                                      |

The same is available from Lua: `require("simple-sidetree").open(dir?)`,
`.close()`, `.toggle()`, `.focus()`, `.switch()`, `.find_file()`, `.refresh()`,
`.is_open()`, and every tree action under `.actions`.

## Highlight groups

All are defined with `default = true`, so your colorscheme or config can override them.

| Group                   | Default link | Used for            |
| ----------------------- | ------------ | ------------------- |
| `SimpleSidetreeRoot`    | `Title`      | Root header line    |
| `SimpleSidetreeFolder`  | `Directory`  | Directory names     |
| `SimpleSidetreeSymlink` | `Special`    | Symlink names       |
| `SimpleSidetreeIcon`    | `Comment`    | Folder arrows / file icon column |

The tree buffer has filetype `simple-sidetree` (handy for statusline plugins
and `FileType` autocmds).

## Development

```sh
# headless test suite (exits non-zero on the first failure)
nvim --headless -u tests/minimal_init.lua -l tests/run.lua

# run only the tests whose name contains a string
TEST_FILTER=rename nvim --headless -u tests/minimal_init.lua -l tests/run.lua

# try it out with a minimal config (mapleader = space)
nvim -u tests/minimal_init.lua
```
