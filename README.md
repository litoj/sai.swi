# `sai.swi`

_Swayimg API Improved_

- The sai (Japanese: 釵, lit. 'hairpin'; Chinese: 鐵尺, lit. 'iron ruler'…)
  [\[Wikipedia\]](<https://en.wikipedia.org/wiki/Sai_(weapon)>)
  - Provides the quality of life improvements and api aesthetics like a hairping
  - Is much more powerful and completely replaces the original api like a sword overrules a stick

## ✨ Features

### Quick Overview

- All basic features that swayimg should have by default.
  - shorter and easier to type when accessing the api
  - `.swi` simple way to say a lua package is made for swayimg - like `.nvim` for neovim
  - allows vim-style mappings - `<C-S-Del>`, `<C-.>`…
  - eventloop system based on neovim lua autocommands - almost everything is listenable
  - all variables can now be set _and_ read - no more caching of the last set value
  - simpler and efficient, yet offers more features and practicality than the original
- Focus on extensibility and ease of use.
- **Custom modes!** - exemplary usage of filtering mode:

https://github.com/user-attachments/assets/5b1e5b56-7f84-4525-b490-6ff0ff6a30be

<details>
<summary>
click to see more
</summary>

- options now accessible as **R+W variables**: `sai.text.size = sai.text.size*1.1`
- **forward compatible**: original api is still directly forwarded through `sai` so all additions
  are available and any setter/enabler and getter methods will automatically be accessible as
  variables, even if not documented yet.
- **eventloop**: subscribe to any change in the api and trigger your own events for messaging
  - inspired by vim event structure and neovim for registering the hooks in lua
  - `e.trigger{event='User', match='help', data={'q: quit', 'j/k: navigate'}}`
- **exif-data loader**:
  - gallery image also with metadata -> just like viewer mode
  - `l.get(true)` hands out the whole list with the metadata loaded:
- **extended text layer templates**:
  - track any api variable: `g.text.topright={'Marked: {sai.imagelist.marked.size}'}`
  - pretty-print exif data: `v.text.topleft={'Exposure: {ExposureTime}'}`
  - dynamic event updates - use eventloop hooks with callbacks returning the text to set
- **custom default scaling modes `keep_xxx`**: aspect-ratio-constant zoom
  - keeps image size instead of pixel zoom
  - useful for comparing identical images of different sizes
  - `xxx` can be replaced with any of the default scaling modes or `keep_size`
  - you can add your own

### Keybinds

- common actions as directly mappable functions:
  ```lua
  v.map('Right', v.go.next) -- image
  v.map('k', v.pan.up)
  v.map('Alt+k', function() v.pan.by(70,70) end)
  ```
- style-agnostic: use gui-, imv- or **vim-style** keybinds or any style that's right for you
  ```lua
  --        gui,      vim,    imv-gui, tripple-ctrl-click
  g.map({ 'Shift+m', '<S- >', 'Alt-h', 'C-3-LMB' }, function()
  	l.marked.set_current 'toggle'
  	g.go.left()
  end)
  ```
- map **shell commands** directly with **ranger-style** file placeholders:
  - `%f`: `'`-quoted current file: `v.map('Ctrl-e', 'xdg-open %f')`
  - `%s`/`%m`: `'`-quoted marked/current files: `v.map('A-s', 'dragon-drop -x -A %s')`
    - `%s`: marked files if in gallery mode, fallbacks to current file (or default in viewer)
    - `%m`: doesn't execute the command if no files were marked
  - `%`: unquoted current (like in 4.x): `v.map('', [[bash -c '$(which trash || echo rm) "%"']])`
- custom modifiers:
  - a block-position prefix (`TL+`/`TR+`/`BL+`/`BR+`/`ST+`) on any key
    - fire only when the mouse is over the rendered text block
      - also provides char-precise position
  - repeated click (`2+LMB`): the nth press within the mode's `multiclick_delay` window

### Custom modes

- base mode ensuring changes get applied only while mode is active: `sai.lib.remapper`
  - temporary variable changes (`.sai`)
  - event hooks (`.sai.eventloop.subscribe`)
  - mappings overrides (`.map()`)
  - automatic help window `.help_pager` with
- text display management: `sai.lib.pager`
  - default scroll binds limited just to the visible area of the displayed textbox
- all other modes have useful value just on their own with minimal changes, therefore they live in
  `sai.mode`
- text (multi-)selection: `sai.mode.selector`
  - adds default binds for selecting a line with a click
  - <kbd>Tab</kbd> to toggle selection of the item under cursor
  - context lines: `.scroll_ahead`
    - a fraction below 1 scales with the page
      - 0.5 to keep the selected line in the center
    - `>=1` for absolute number of context lines from both ends
- text input and editing: `sai.mode.editor`
  - allows you to input arbitrary text and do whatever you want with it
  - **utf8-aware**: the cursor and all motions work on characters, not bytes
  - multiline text selection
  - supports mouse clicking for changing cursor position
  - support for all common gui keyboard text-editing shortcuts
    - selection with Shift of everything for jumping (<kbd>Shift+Left</kbd>,
      <kbd>Shift+Ctrl+Home</kbd>)
    - clipboard support (select all <kbd>Ctrl+a</kbd>, <kbd>Ctrl+c/v/x</kbd>)

#### Mini-modes

Ready-to-go modes for your convenience. These modes are simple helpers that are not expected to be
further extended.

- **key_help**: tab for every active mode with sub-categories for per-component binds
  - toggle with <kbd>F1</kbd> or <kbd>?</kbd> between _on_, _include overriden mappings_, _off_
  - to disable vim-style kbd printing set `kh.short_binds = false`
- **var_help**: tab for all api settings + settings of all currently active mode
  - toggle with <kbd>Shift+F1</kbd>
    <img width="1256" height="764" alt="Image of help mode in the settings section" src="https://github.com/user-attachments/assets/1393488e-a0ba-4bd4-8f9a-26c314ecb112" />
- **text_adjust**: change the looks of the visible text boxes live (height, scrolloff, location)
  - toggle with <kbd>F2</kbd>
- **lua_mode/shell_mode**: for live-evaluating code - keeps history (switch with arrows)
- **two-pane mode** for comparing images (limited by the gallery scaling implementation)

#### Filter mode

- live filtering by exif data or any other image info
- tab completion for image properties to filter by
- configurable display options - what to live-update (completion, images, filter list…)
- filtering by multiple metrics and operators
- config options (see <./mode/image_filter.lua> for more details):
  ```lua
  local fm = require('sai.mode.image_filter').new {
  	_location = 'topleft',
  	-- Public, changeable at any time
  	update_imagelist_on_confirm = true, ---Should imagelist be set to filtered images
  	live_imagelist = true, ---Should imagelist be updated with filtering
  	results_list = true, ---Should a pager with the filtered files be displayed
  	---Should a completion menu for the current tag be visible
  	---`'i'` for matching with ignored casing
  	completion = true, ---@type false|'i'|true
  }
  ```

#### Sort mode

- interactive sorting of the image list
- a status-bar input (`Filter`) drives two panes, each with a cursor:
  - top left: the pool of unpicked fields - list fields or any exif tag of the current images
  - bottom left: the picked sort keys, in their order
- multi-key comparators: later keys break the ties; missing values last on ascending keys (first on
  descending ones)
- custom value transforms: the code, evaluated with `return `, computes the value to compare for one
  entry - `self` holds the named field or tag's value (the images themselves for a `self` line, like
  the filter mode's `:` operator); the key then compares the values like a plain field, so the code
  only produces the value, never the comparison - and it must return a string or a number
  - `name:code` + <kbd>Tab</kbd>: add it as a picked key, e.g. sorting by the time (not the date)
    the photo was taken - `Exif.Photo.DateTimeOriginal:self:sub(12)`
  - `:code` + <kbd>Tab</kbd>: attach to the key under the picked pane's cursor (a completed tag
    lands in the picked list right away; an empty pane takes a `self` line)
  - <kbd>Ctrl+p</kbd>: prefill the current key's name and code into the input - <kbd>Tab</kbd> after
    an edit updates that line in place
  - flipping such a key reverses the comparison
- the image order live-updates with every change
  - <kbd>Enter</kbd> confirms (only with an empty input, so an in-flight edit cannot slip out) and
    keeps the comparator set (`sai.imagelist.order`)
  - aborting restores the order active on entry

#### Tag edit mode

- edit the exif tags of the marked files (or the current one): pick a tag from a completion pool of
  every loaded tag, then set its value
- keys:
  - <kbd>Enter</kbd>: pick the typed tag, then write the value - an empty value deletes the tag (a
    second <kbd>Enter</kbd> confirms)
  - <kbd>Tab</kbd>: complete with the candidate under the pane cursor
  - <kbd>Escape</kbd>: drop the picked tag; the second press aborts
- editing several tags at once: <kbd>Enter</kbd> on a name without a dot expands it to every loaded
  tag with that leaf name (like exiftool's `-all:`) - the value, or the deletion, writes to all of
  them

### [Snippets](./snippets.lua)

A collection of small code snippets that might be often wanted. Or can just serve as an inspiration
for your own scripts.

Snippets include:

- loading the current directory when swayimg opened with just 1 image
- printing a status message on every variable change (like it used to be)
- resizing the image with the window if the image is in not zoomed in
- automatically open video in viewer mode (and close on switch) using your command (`mpv` by
  default)
- cycling fixed scaling and position modes
- notifying on shell command output
- lua and shell snippet modes for live-executing code with per-mode history support
- two-pane mode for viewing images side-by-side

### IPC

Expose a Unix socket for external programs to evaluate Lua code in swayimg.

```lua
-- inside swayimg:
local ipc = require 'sai.bridge.ipc'
local server = ipc.server('/tmp/swi.sock') -- auto-enabled
-- from any external program (the in-process client cannot complete a
-- round trip: the server polls from the eventloop):
local client = ipc.client('/tmp/swi.sock') -- auto-enabled
print(client:send("return sai.text.size")) --> current font size
-- functions work too: sent as bytecode, must be self-contained (globals
-- resolve inside swayimg, client locals/upvalues do not travel)
print(client:send(function() return sai.text.size end))
client.enabled = false
server.enabled = false -- inside swayimg again, to stop serving
```

### ⚠️ Limitations

True eventloop used by swayimg internally is still inaccessible. That means we cannot listen for
file updates and save image state (like scale, position, etc.) before the image gets changed.

</details>

## 🚀 Geting Started

Clone the repo into your swayimg config to `sai` _(not `sai.swi`!)_.

```sh
git clone https://github.com/litoj/sai.swi ~/.config/swayimg/sai
```

_Don't forget to add it to `.gitignore`, if you version your dotfiles_

You can add a keybind to update swayimg:

```lua
v.map('Alt+F5', require('sai.snippets').update) -- for just viewer mode

local map = require 'sai.binds' -- for any mode combo
map('a', 'A-F5', require('sai.snippets').update)
```

### Use the API

To start using the api you only need to load the main module. However, if you also want to use all
the main APIs as globals, you can also load `sai.globals` to have easier access to them. The
structure is declared in [types.lua](./types.lua)

```lua
-- ~/.config/swayimg/init.lua
-- makes the api accessible through the `sai` global variable
-- you can also just save it to whatever you want
require 'sai.api.init'
-- or through first-letter globals (except: sai.imagelist -> `l` - not `i`)
require 'sai.api.globals'

-- now you can use all options as variables and make intricate behaviour using eventloop hooks
```

## 🔧 Development

### Structure

- `api/`: everything related just to the replacement of the swayimg api + `eventloop` more generic
  event handler
- `bridge/`: everything that talks to the world outside - using lua `ffi`, C, shell, etc.
  - C/C++ modules compile on first `require`: `sai.bridge.exiv2` builds `bridge/exiv2.so` from its
    `.cpp` source
  - `sai.bridge.utf8` provides the utf8 module as in Lua 5.3+: a system installation (e.g. the
    `lua51-luautf8` package, including its `find`/`gmatch`/`gsub` extras) is used when present,
    otherwise the stock Lua 5.3 C source is downloaded (patched for LuaJIT) and compiled on first
    `require`; the callable form `utf8(s)` coerces any string into a valid utf8 string
- `lib/`: pure-Lua utilities extending the possibilities for building your own scripts and plugins
- `mode/`: custom modes ready to go or to be extended

### Dev experience in nvim

_sai_ reuses the types of the original swayimg api. Add them to your _lua_ls_ workspace:

```lua
settings.Lua.workspace.library = {'/usr/share/swayimg/swayimg.lua', '/usr/local/share/swayimg/swayimg.lua'}
```

### Debugging in nvim

Ensure you have `lua51-cjson` installed.

_sai_ has a DAP harness (`bridge/debug.lua`) and an nvim-dap adapter (`nvim_dap.lua`). Debug a
running swayimg from nvim: set breakpoints, step, evaluate. While stopped, the harness freezes the
swayimg event loop.

The adapter is not a nvim plugin. It lives in the swayimg config directory. Load it straight from
there:

```lua
-- registers in dap.configurations.lua and the `sai` adapter
loadfile(os.getenv 'HOME' .. '/.config/swayimg/sai/nvim_dap.lua')().setup()
```

Start the harness in swayimg via pressing <kbd>Shift+F6</kbd> or running:

```lua
require('sai.bridge.debug').start {} -- $XDG_RUNTIME_DIR/sai-debug-<pid>.sock
```

`setup()` registers the `sai` adapter and an 'Attach to swayimg' configuration that nvim-dap offers
only when the current file lives under a swayimg directory, like osv does for nvim itself. Debug lua
as usual - your nvim-dap bindings pick it up.

### Tests

Each test module is named after the sai module it exercises. All tests run end-to-end, over real
processes. The modules also double as usage documentation: the headers of tests/eventloop.lua,
tests/reconfigurer.lua and tests/ipc.lua state the api idiom their scenarios demonstrate,
tests/utf8.lua or tests/xkb.lua read as input/output tables for their bridges, and
tests/remapper.lua shows how to write a custom mode (each test builds its modes with the public api
calls). Run it from anywhere:

```sh
luajit tests/init.lua                     # all tests
luajit tests/debug.lua                    # one module
luajit tests/init.lua debug.breakpoints   # one method
```

### TODOs

(done by the ui refactor: one-shot user prompts via `sai.lib.ui`, unified pager/editor text display,
generalized filtering (`sai.lib.filter`) and completion (`sai.mode.completion`), and the interactive
sort mode (`sai.mode.sort`) with mouse line mapping and re-sort on list changes)

- filter mode should show completion of values when the current line already has a tag and an
  operator. The completion should fuzzy-match against the value that is being written (or evaluate
  the actual filter for just the single line in case of code filter)
- fm mode: follow symlinks, walk the tree, open files/folders by adding or replacing current list
  - dir mode could also be normal gallery
    - pick first image from each dir
    - custom gallery text layer - compute sizes and pos for text and use BL+BR to overlay images
- live var mode: filter variables and view and change their live values (like mpv `gv`)
- touchpad scroll speed control
- make it easier to make multi-level keybinds (like vim `cd/ce/cb…`)
- make a snippet for loading keybind config from ranger

## License

Do whatever you please but don't lie about what it is.
