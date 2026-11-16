-- Headless tests:
--   nvim --headless -u tests/minimal_init.lua -l tests/run.lua
local api = vim.api
local uv = vim.uv or vim.loop

local st = require("simple-sidetree")
local view = require("simple-sidetree.view")
local tree = require("simple-sidetree.tree")
local actions = require("simple-sidetree.actions")

-- Fixture ---------------------------------------------------------------------

local TMP = vim.fn.resolve(vim.fn.tempname())
local function p(rel)
  return TMP .. "/" .. rel
end
local function write(rel, text)
  vim.fn.mkdir(vim.fn.fnamemodify(p(rel), ":h"), "p")
  vim.fn.writefile({ text or rel }, p(rel))
end

local function make_fixture()
  vim.fn.delete(TMP, "rf")
  vim.fn.mkdir(TMP, "p")
  vim.fn.mkdir(p("A_dir"), "p")
  write("b_dir/inner.txt")
  write("b_dir/sub/deep.txt")
  vim.fn.mkdir(p(".hidden_dir"), "p")
  write(".dotfile")
  write("a.txt")
  write("B.md")
  write("z.txt")
  assert(uv.fs_symlink(p("b_dir"), p("link_to_dir")))
end

-- Helpers ---------------------------------------------------------------------

local function eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\n  actual: %s"):format(msg or "values differ", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function ok(cond, msg)
  if not cond then
    error(msg or "assertion failed", 2)
  end
end

local function wait_for(cond, msg)
  ok(vim.wait(1000, cond, 10), "timed out waiting for: " .. (msg or "condition"))
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function tree_lines()
  return api.nvim_buf_get_lines(view.buf, 0, -1, false)
end

local function normal_wins()
  local wins = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(w).relative == "" then
      wins[#wins + 1] = w
    end
  end
  return wins
end

local function main_win()
  for _, w in ipairs(normal_wins()) do
    if w ~= view.get_win() then
      return w
    end
  end
end

---Put the tree cursor on `rel` (relative to TMP) and focus the tree.
local function cursor_to(rel)
  local win = assert(view.get_win(), "tree not open")
  api.nvim_set_current_win(win)
  local line = tree.find_line(p(rel))
  ok(line, "no tree line for " .. rel .. "\n" .. table.concat(tree_lines(), "\n"))
  api.nvim_win_set_cursor(win, { line, 0 })
end

local function stub_input(answer)
  vim.ui.input = function(opts, cb)
    cb(type(answer) == "function" and answer(opts) or answer)
  end
end

local function stub_confirm(choice)
  vim.fn.confirm = function()
    return choice
  end
end

local function reset(opts)
  -- a fresh tab gives a fresh window that was never a tree window
  vim.cmd("silent! tabnew")
  pcall(vim.cmd, "silent! tabonly!")
  vim.wait(20) -- let scheduled autocmd callbacks from the last test run
  for _, b in ipairs(api.nvim_list_bufs()) do
    if b ~= api.nvim_get_current_buf() then
      pcall(api.nvim_buf_delete, b, { force = true })
    end
  end
  make_fixture()
  vim.cmd("cd " .. vim.fn.fnameescape(TMP))
  tree.root = nil
  tree.line_nodes = {}
  view.prev_win = {}
  st.setup(vim.tbl_deep_extend("force", { quit_on_last_window = false }, opts or {}))
  tree.set_root(TMP)
end

-- Tests -----------------------------------------------------------------------

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

test("open creates a fixed-width side window on the left", function()
  reset()
  st.open()
  local win = view.get_win()
  ok(win, "tree window exists")
  eq(2, #normal_wins(), "window count")
  eq(win, api.nvim_get_current_win(), "tree is focused after open")
  eq(1, vim.fn.win_screenpos(win)[2], "tree is leftmost")
  eq(30, api.nvim_win_get_width(win), "width")
  eq(true, vim.wo[win].winfixwidth, "winfixwidth")
  eq(false, vim.wo[win].number, "nonumber")
  eq("simple-sidetree", vim.bo[view.buf].filetype, "filetype")
  eq(false, vim.bo[view.buf].modifiable, "nomodifiable")
  -- the main window is untouched
  local main = main_win()
  eq(false, vim.wo[main].winfixwidth, "main window has no winfixwidth")
end)

test("side = right and custom width", function()
  reset({ side = "right", width = 25 })
  st.open()
  local win = view.get_win()
  eq(25, api.nvim_win_get_width(win), "width")
  ok(vim.fn.win_screenpos(win)[2] > 1, "tree is on the right")
  local main = main_win()
  ok(vim.fn.win_screenpos(main)[2] < vim.fn.win_screenpos(win)[2], "main is left of tree")
end)

test("renders directories first, sorted, dotfiles hidden", function()
  reset()
  st.open()
  eq({
    vim.fn.fnamemodify(TMP, ":~"),
    "▸ A_dir",
    "▸ b_dir",
    "▸ link_to_dir",
    "  a.txt",
    "  B.md",
    "  z.txt",
  }, tree_lines(), "lines")
end)

test("toggle_hidden shows dotfiles", function()
  reset()
  st.open()
  actions.toggle_hidden()
  local lines = tree_lines()
  ok(vim.tbl_contains(lines, "▸ .hidden_dir"), "hidden dir shown")
  ok(vim.tbl_contains(lines, "  .dotfile"), "dotfile shown")
  eq("▸ .hidden_dir", lines[2], "dot dirs sort first")
  actions.toggle_hidden()
  ok(not vim.tbl_contains(tree_lines(), "  .dotfile"), "dotfile hidden again")
end)

test("open on a directory expands and collapses it", function()
  reset()
  st.open()
  cursor_to("b_dir")
  actions.open()
  local lines = tree_lines()
  eq("▾ b_dir", lines[3], "arrow open")
  eq("  ▸ sub", lines[4], "child dir indented")
  eq("    inner.txt", lines[5], "child file indented")
  eq(3, api.nvim_win_get_cursor(0)[1], "cursor stays on the directory")
  actions.open()
  eq("▸ b_dir", tree_lines()[3], "collapsed")
  eq("▸ link_to_dir", tree_lines()[4], "children gone")
end)

test("symlinked directories expand and are highlighted", function()
  reset()
  st.open()
  cursor_to("link_to_dir")
  actions.open()
  ok(tree.find_line(p("link_to_dir/inner.txt")), "symlink dir children listed")
  local marks = api.nvim_buf_get_extmarks(view.buf, tree.ns, 0, -1, { details = true })
  local found = false
  for _, m in ipairs(marks) do
    if m[4].hl_group == "SimpleSidetreeSymlink" then
      found = true
    end
  end
  ok(found, "SimpleSidetreeSymlink highlight applied")
end)

test("close_dir collapses the parent from a child", function()
  reset()
  st.open()
  cursor_to("b_dir")
  actions.open()
  cursor_to("b_dir/inner.txt")
  actions.close_dir()
  eq("▸ b_dir", tree_lines()[3], "parent collapsed")
  eq(3, api.nvim_win_get_cursor(0)[1], "cursor on parent")
end)

test("<leader><Tab> switches tree -> main -> tree", function()
  reset()
  local main = api.nvim_get_current_win()
  feed("<leader><Tab>")
  local win = view.get_win()
  ok(win, "first press opens the tree")
  eq(win, api.nvim_get_current_win(), "tree focused")
  feed("<leader><Tab>")
  eq(main, api.nvim_get_current_win(), "back in main")
  feed("<leader><Tab>")
  eq(win, api.nvim_get_current_win(), "tree again")
end)

test("switch returns to the last used main window", function()
  reset()
  local first = api.nvim_get_current_win()
  vim.cmd("vsplit")
  local second = api.nvim_get_current_win()
  st.open()
  api.nvim_set_current_win(first)
  st.switch()
  eq(view.get_win(), api.nvim_get_current_win(), "in tree")
  st.switch()
  eq(first, api.nvim_get_current_win(), "returned to the window we came from")
  ok(second ~= first)
end)

test("switch creates a main window if the tree is alone", function()
  reset()
  st.open()
  vim.cmd("only")
  eq(1, #normal_wins(), "tree alone")
  st.switch()
  eq(2, #normal_wins(), "main window created")
  ok(api.nvim_get_current_win() ~= view.get_win(), "focus in new main window")
  eq(false, vim.wo.winfixwidth, "new main window does not inherit winfixwidth")
  eq(vim.go.number, vim.wo.number, "new main window uses global 'number'")
  ok(not vim.w.simple_sidetree, "new main window is not marked as tree")
  eq(30, api.nvim_win_get_width(view.get_win()), "tree width kept")
end)

test("custom switch keymap and disabled keymap", function()
  reset({ keymaps = { switch = "<C-n>" } })
  eq("", vim.fn.maparg("<leader><Tab>", "n"), "old mapping removed")
  local main = api.nvim_get_current_win()
  feed("<C-n>")
  eq(view.get_win(), api.nvim_get_current_win(), "<C-n> opens and focuses the tree")
  feed("<C-n>")
  eq(main, api.nvim_get_current_win(), "<C-n> goes back")

  reset({ keymaps = { switch = false } })
  eq("", vim.fn.maparg("<C-n>", "n"), "custom mapping removed")
  eq("", vim.fn.maparg("<leader><Tab>", "n"), "no switch mapping")
end)

test("keymaps.toggle", function()
  reset({ keymaps = { toggle = "<leader>e" } })
  feed("<leader>e")
  ok(view.is_open(), "toggle opens")
  feed("<leader>e")
  ok(not view.is_open(), "toggle closes")
end)

test("opening a file uses the main window, not the tree window", function()
  reset()
  local main = api.nvim_get_current_win()
  st.open()
  cursor_to("a.txt")
  actions.open()
  eq(main, api.nvim_get_current_win(), "focus moved to main")
  eq(p("a.txt"), api.nvim_buf_get_name(api.nvim_win_get_buf(main)), "file in main")
  eq(view.buf, api.nvim_win_get_buf(view.get_win()), "tree window still shows the tree")
  eq(2, #normal_wins(), "no extra windows")
end)

test("vsplit / split / tabnew", function()
  reset()
  st.open()
  cursor_to("a.txt")
  actions.vsplit()
  eq(3, #normal_wins(), "vsplit adds a window")
  eq(p("a.txt"), api.nvim_buf_get_name(0), "vsplit file")
  eq(30, api.nvim_win_get_width(view.get_win()), "tree width kept after vsplit")
  cursor_to("B.md")
  actions.split()
  eq(4, #normal_wins(), "split adds a window")
  eq(p("B.md"), api.nvim_buf_get_name(0), "split file")
  cursor_to("z.txt")
  actions.tabnew()
  eq(2, #api.nvim_list_tabpages(), "new tab")
  eq(p("z.txt"), api.nvim_buf_get_name(0), "tab file")
end)

test("opening a file when the tree is alone creates a main window", function()
  reset()
  st.open()
  vim.cmd("only")
  cursor_to("a.txt")
  actions.open()
  eq(2, #normal_wins(), "main window created")
  eq(p("a.txt"), api.nvim_buf_get_name(0), "file opened")
  eq(30, api.nvim_win_get_width(view.get_win()), "tree width")
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(b) and vim.bo[b].buflisted and api.nvim_buf_get_name(b) == "" and b ~= api.nvim_get_current_buf() then
      -- the initial [No Name] from reset() is fine, but it must not be shown
      ok(#vim.fn.win_findbuf(b) == 0, "no stray empty window")
    end
  end
end)

test("close_on_open", function()
  reset({ close_on_open = true })
  st.open()
  cursor_to("a.txt")
  actions.open()
  ok(not view.is_open(), "tree closed after opening")
  eq(p("a.txt"), api.nvim_buf_get_name(0), "file opened")
end)

test("add creates files, nested paths and directories", function()
  reset()
  st.open()
  cursor_to("b_dir")
  local default
  stub_input(function(opts)
    default = opts.default
    return opts.default .. "new.lua"
  end)
  actions.add()
  eq(p("b_dir") .. "/", default, "default is the directory under the cursor")
  ok(vim.fn.filereadable(p("b_dir/new.lua")) == 1, "file created")
  eq(tree.find_line(p("b_dir/new.lua")), api.nvim_win_get_cursor(view.get_win())[1], "cursor on new file")

  cursor_to("a.txt")
  stub_input(function(opts)
    default = opts.default
    return opts.default .. "x/y/deep.lua"
  end)
  actions.add()
  eq(TMP .. "/", default, "default for a file is its parent")
  ok(vim.fn.filereadable(p("x/y/deep.lua")) == 1, "nested file created")
  ok(tree.find_line(p("x/y/deep.lua")), "nested file revealed")

  stub_input(p("newdir") .. "/")
  actions.add()
  eq(1, vim.fn.isdirectory(p("newdir")), "directory created")
  ok(tree.find_line(p("newdir")), "directory shown")

  -- refuses to overwrite
  local errors = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = msg
    end
  end
  stub_input(p("a.txt"))
  actions.add()
  vim.notify = orig_notify
  eq(1, #errors, "error on existing file")
  eq({ "a.txt" }, vim.fn.readfile(p("a.txt")), "existing file untouched")
end)

test("rename moves the file and renames its buffer", function()
  reset()
  st.open()
  cursor_to("a.txt")
  actions.open()
  local buf = api.nvim_get_current_buf()
  cursor_to("a.txt")
  stub_input(p("b_dir/renamed.txt"))
  actions.rename()
  ok(vim.fn.filereadable(p("a.txt")) == 0, "old path gone")
  ok(vim.fn.filereadable(p("b_dir/renamed.txt")) == 1, "new path exists")
  eq(p("b_dir/renamed.txt"), api.nvim_buf_get_name(buf), "buffer renamed")
  eq(tree.find_line(p("b_dir/renamed.txt")), api.nvim_win_get_cursor(view.get_win())[1], "cursor on renamed file")
  eq(-1, vim.fn.bufnr(p("a.txt")), "no buffer left for the old name")
  api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
end)

test("rename a directory renames buffers inside it", function()
  reset()
  st.open()
  api.nvim_set_current_win(main_win())
  vim.cmd("edit " .. vim.fn.fnameescape(p("b_dir/sub/deep.txt")))
  local buf = api.nvim_get_current_buf()
  cursor_to("b_dir")
  stub_input(p("c_dir"))
  actions.rename()
  ok(vim.fn.isdirectory(p("c_dir/sub")) == 1, "directory moved")
  eq(p("c_dir/sub/deep.txt"), api.nvim_buf_get_name(buf), "buffer inside renamed")
end)

test("delete removes files and wipes their buffers", function()
  reset()
  st.open()
  cursor_to("z.txt")
  actions.open()
  local main = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  cursor_to("z.txt")
  stub_confirm(2)
  actions.delete()
  ok(vim.fn.filereadable(p("z.txt")) == 1, "'No' keeps the file")
  stub_confirm(1)
  actions.delete()
  ok(vim.fn.filereadable(p("z.txt")) == 0, "file deleted")
  ok(not api.nvim_buf_is_valid(buf), "buffer wiped")
  ok(api.nvim_win_is_valid(main), "main window kept")
  ok(not tree.find_line(p("z.txt")), "tree updated")
end)

test("delete keeps modified buffers and deletes directories recursively", function()
  reset()
  st.open()
  api.nvim_set_current_win(main_win())
  vim.cmd("edit " .. vim.fn.fnameescape(p("b_dir/inner.txt")))
  local buf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
  cursor_to("b_dir")
  stub_confirm(1)
  local orig_notify = vim.notify
  vim.notify = function() end
  actions.delete()
  vim.notify = orig_notify
  eq(0, vim.fn.isdirectory(p("b_dir")), "directory deleted")
  ok(api.nvim_buf_is_valid(buf) and vim.bo[buf].modified, "modified buffer kept")
end)

test("delete a symlink removes only the link", function()
  reset()
  st.open()
  cursor_to("link_to_dir")
  stub_confirm(1)
  actions.delete()
  ok(not uv.fs_lstat(p("link_to_dir")), "link removed")
  ok(vim.fn.filereadable(p("b_dir/inner.txt")) == 1, "target untouched")
end)

test("dir_up and cd change the root", function()
  reset()
  st.open()
  cursor_to("b_dir")
  actions.cd()
  eq(p("b_dir"), tree.root.path, "cd sets root")
  eq(vim.fn.fnamemodify(p("b_dir"), ":~"), tree_lines()[1], "header updated")
  actions.dir_up()
  eq(TMP, tree.root.path, "dir_up goes to parent")
  eq("▾ b_dir", tree_lines()[3], "old root stays expanded")
  eq(3, api.nvim_win_get_cursor(view.get_win())[1], "cursor on old root")
  -- open on the header line goes up too
  api.nvim_win_set_cursor(view.get_win(), { 1, 0 })
  actions.open()
  eq(vim.fn.fnamemodify(TMP, ":h"), tree.root.path, "header <CR> goes up")
end)

test("refresh picks up new files and keeps expanded directories", function()
  reset()
  st.open()
  cursor_to("b_dir")
  actions.open()
  write("b_dir/added.txt")
  write("new_top.txt")
  actions.refresh()
  ok(tree.find_line(p("b_dir/added.txt")), "new nested file")
  ok(tree.find_line(p("new_top.txt")), "new top file")
  eq("▾ b_dir", tree_lines()[3], "still expanded")
end)

test("BufWritePost refreshes the tree", function()
  reset()
  st.open()
  api.nvim_set_current_win(main_win())
  vim.cmd("edit " .. vim.fn.fnameescape(p("written.txt")))
  vim.cmd("silent write")
  ok(tree.find_line(p("written.txt")), "written file appears")
end)

test("DirChanged sets the root", function()
  reset()
  st.open()
  vim.cmd("cd " .. vim.fn.fnameescape(p("b_dir")))
  eq(p("b_dir"), tree.root.path, "root follows :cd")
end)

test("BufWinEnter guard keeps the tree window for the tree", function()
  reset()
  local main = api.nvim_get_current_win()
  st.open()
  local win = view.get_win()
  vim.cmd("edit " .. vim.fn.fnameescape(p("a.txt")))
  wait_for(function()
    return api.nvim_win_get_buf(win) == view.buf
  end, "tree buffer restored")
  eq(p("a.txt"), api.nvim_buf_get_name(api.nvim_win_get_buf(main)), "file moved to main window")
  eq(main, api.nvim_get_current_win(), "focus in main window")
  eq(30, api.nvim_win_get_width(win), "tree width")
  eq(false, vim.wo[win].number, "tree options restored")
end)

test("follow_current_file reveals the current buffer", function()
  reset({ follow_current_file = true })
  st.open()
  api.nvim_set_current_win(main_win())
  vim.cmd("edit " .. vim.fn.fnameescape(p("b_dir/sub/deep.txt")))
  wait_for(function()
    local line = tree.find_line(p("b_dir/sub/deep.txt"))
    return line ~= nil and api.nvim_win_get_cursor(view.get_win())[1] == line
  end, "tree cursor on current file")
  ok(api.nvim_get_current_win() ~= view.get_win(), "focus unchanged")
end)

test("SimpleSidetreeFindFile reveals the current file", function()
  reset()
  vim.cmd("edit " .. vim.fn.fnameescape(p("b_dir/sub/deep.txt")))
  vim.cmd("SimpleSidetreeFindFile")
  eq(view.get_win(), api.nvim_get_current_win(), "tree focused")
  eq(tree.find_line(p("b_dir/sub/deep.txt")), api.nvim_win_get_cursor(0)[1], "cursor on file")
end)

test("user commands open / close / toggle / focus", function()
  reset()
  vim.cmd("SimpleSidetreeOpen " .. vim.fn.fnameescape(p("b_dir")))
  ok(view.is_open(), "open")
  eq(p("b_dir"), tree.root.path, "open with dir sets root")
  vim.cmd("SimpleSidetreeOpen " .. vim.fn.fnameescape(TMP))
  eq(vim.fn.fnamemodify(TMP, ":~"), tree_lines()[1], "re-open with a dir re-renders")
  vim.cmd("SimpleSidetreeClose")
  ok(not view.is_open(), "close")
  vim.cmd("SimpleSidetreeToggle")
  ok(view.is_open(), "toggle open")
  vim.cmd("wincmd p")
  vim.cmd("SimpleSidetreeFocus")
  eq(view.get_win(), api.nvim_get_current_win(), "focus")
  vim.cmd("SimpleSidetreeToggle")
  ok(not view.is_open(), "toggle close")
  vim.cmd("SimpleSidetreeRefresh")
end)

test("close leaves an empty window when the tree is alone", function()
  reset()
  st.open()
  vim.cmd("only")
  st.close()
  ok(not view.is_open(), "tree closed")
  eq(1, #normal_wins(), "one window left")
end)

test("each tab gets its own tree window", function()
  reset()
  st.open()
  local win1 = view.get_win()
  vim.cmd("tabnew")
  ok(not view.is_open(), "not open in the new tab")
  st.open()
  local win2 = view.get_win()
  ok(win2 and win2 ~= win1, "separate window")
  eq(api.nvim_win_get_buf(win1), api.nvim_win_get_buf(win2), "shared buffer")
end)

test("quit_on_last_window closes a tab left with only the tree", function()
  reset({ quit_on_last_window = true })
  vim.cmd("tabnew")
  local main = api.nvim_get_current_win()
  st.open()
  eq(2, #api.nvim_list_tabpages(), "two tabs")
  api.nvim_win_close(main, true)
  wait_for(function()
    return #api.nvim_list_tabpages() == 1
  end, "tab closed")
end)

test("help float lists mappings and closes with q", function()
  reset()
  st.open()
  local float = actions.help()
  ok(api.nvim_win_is_valid(float), "float open")
  local text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(float), 0, -1, false), "\n")
  ok(text:find("g%?") and text:find("Rename"), "lists mappings")
  feed("q")
  ok(not api.nvim_win_is_valid(float), "q closes float")
end)

test("mappings can be disabled or replaced", function()
  reset({ mappings = { d = false, ["<C-x>"] = "delete", ["gx"] = function() end } })
  st.open()
  eq("", vim.fn.maparg("d", "n"), "d disabled")
  ok(vim.fn.maparg("<C-x>", "n") ~= "" or #vim.fn.maparg("<C-x>", "n", false, true) > 0, "<C-x> mapped")
  ok(not vim.tbl_isempty(vim.fn.maparg("gx", "n", false, true)), "custom function mapped")
end)

-- Runner ----------------------------------------------------------------------

local only = os.getenv("TEST_FILTER")
local passed = 0
for _, t in ipairs(tests) do
  if not only or t.name:find(only, 1, true) then
    local ok_, e = xpcall(t.fn, debug.traceback)
    if not ok_ then
      io.stdout:write("FAIL  " .. t.name .. "\n" .. tostring(e) .. "\n")
      vim.fn.delete(TMP, "rf")
      vim.cmd("cquit 1")
    end
    passed = passed + 1
    io.stdout:write("ok    " .. t.name .. "\n")
  end
end
vim.fn.delete(TMP, "rf")
io.stdout:write(("\n%d tests passed\n"):format(passed))
vim.cmd("qa!")
