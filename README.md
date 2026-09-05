# `sai.swi`

_Swayimg API Improved_

- The sai (Japanese: 釵, lit. 'hairpin'; Chinese: 鐵尺, lit. 'iron ruler'…)
  [\[Wikipedia\]](<https://en.wikipedia.org/wiki/Sai_(weapon)>)
  - Provides the quality of life improvements and api aesthetics like a hairping
  - Is much more powerful and completely replaces the original api like a sword overrules a stick

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

## ✨ Complete list of Features (_click to expand_)

</summary>

- options now accessible as variables: `sai.text.size = sai.text.size*1.1`
- forward compatible: original api is still directly forwarded through `sai` so all additions are
  available and any setter/enabler and getter methods will automatically be accessible as variables,
  even if not documented yet.
- common actions as directly mappable functions:
  ```lua
  v.map('Right', v.go.next) -- image
  v.map('k', v.pan.up)
  v.map('Alt+k', function() v.pan.by(70,70) end)
  ```
- **eventloop**: subscribe to any change in the api and trigger your own events for messaging
  - inspired by vim event structure and neovim for registering the hooks in lua
- exifdata loader:
  - gallery image lazy-loads metadata -> just like viewer mode
  - to load all, run `local list=l.get(); require'exiv2'.load_all(list)`
- text layer templates:
  - track any api variable: `g.text.topright={'Marked: {sai.imagelist.marked.size}'}`
  - pretty-print exif data: `v.text.topleft={'Exposure: {ExposureTime}'}`
  - dynamic event updates - use eventloop hooks to update the text dynamically:
    ```lua
    v.text.topright={
      {event='User', pattern='help', function(ev)
        if not ev or not ev.data then return 'Ready to receive messages' end
        if type(ev.data) == 'string' then
          return 'Accepts multiline string:\t' .. ev.data
        elseif type(ev.data) == 'table' then
          table.insert(data, 1, 'Accepts lines as a table (keybind list):')
          return ev.data
        end
      end}
      [100] = 'Surely the message is shorter than 100 lines and won\'t override this'
    }
    e.trigger{event='User', match='help', data=U.str_bindlist(sai.mode.input)}
    ```
- style-agnostic keybinds: use gui-, imv- or **vim-style** keybinds or any style that's right for
  you
  ```lua
  --        gui,      vim,    imv-gui, tripple-ctrl-click
  g.map({ 'Shift+m', '<S- >', 'Alt-h', 'C-3-LMB' }, function()
  	l.marked.set_current 'toggle'
  	g.go.left()
  end)
  ```
- map **shell commands** directly with **ranger-style** file placeholders:
  - `%f`: `'`-quoted current file: `v.map('Ctrl-e', 'xdg-open %f')`
  - `%s`/`%m`: `'`-quoted marked/selected files: `v.map('A-s', 'dragon-drop -x -A %s')`
    - `%s`: fallbacks to current file
    - `%m`: doesn't execute the command if no files were marked
  - `%`: unquoted current (like in 4.x): `v.map('', [[bash -c '$(which trash || echo rm) "%"']])`
- **utf8** input support with compose keys etc. all included
- **IPC**: expose a Unix socket for external programs to evaluate Lua code in swayimg.
  ```lua
  local ipc = require 'sai.bridge.ipc'
  local server = ipc.server('/tmp/swi.sock') -- auto-enabled
  local client = ipc.client('/tmp/swi.sock') -- auto-enabled
  print(client:send("return sai.text.size")) --> current font size
  -- functions work too: sent as bytecode, must be self-contained (globals
  -- resolve inside swayimg, client locals/upvalues do not travel)
  print(client:send(function() return sai.text.size end))
  client.enabled = false
  server.enabled = false
  ```

### Custom modes

- temporary changes to the api through `sai.lib.remapper` instances - see `snippets.two_pane_mode`
- variable changes, with the option to let the user adjust them
- automatic event subscriptions and deletions
- custom keybinds, automatically listed in a **key help mode** tab (no control keybinds;
  <kbd>F1</kbd> gives the full mode)

#### Sealed modes

These are modes that aren't meant to be extended or reused, they are just one singleton instance you
can configure.

- custom **key help mode** with a tab for every active bind layer - the current mode plus each
  enabled custom mode overriding it - so you always know which keybinds come from where (toggled
  with <kbd>F1</kbd> or <kbd>?</kbd>)
  - `require('sai.mode.key_help').short_binds = true` shows binds in the compact form (`C-x`,
    `A-y`…) instead of the full xkb names
- custom **variable help mode** with a tab for all live-updated settings plus, for every active
  custom mode, a tab listing the variables it currently overrides (toggled with <kbd>Shift+F1</kbd>)
  <img width="1256" height="764" alt="Image of help mode in the settings section" src="https://github.com/user-attachments/assets/1393488e-a0ba-4bd4-8f9a-26c314ecb112" />
- **command mode** for live-evaluating lua code (example of extending **input mode**)
- **two-pane mode** for comparing images (limited by the gallery scaling implementation)

#### Input mode

- allows you to input arbitrary text and do whatever you want with it
- utf8-aware: the cursor and all motions work on characters, not bytes
- multiline text
- text selection
- support for all common gui keyboard shortcuts
  - deletion (del prev word <kbd>Ctrl+BS</kbd>…)
  - jumping around (prev word <kbd>Ctrl+Left</kbd>, EOF <kbd>Ctrl+End</kbd>)
  - selection with Shift of everything for jumping (<kbd>Shift+Left</kbd>,
    <kbd>Shift+Ctrl+Home</kbd>)
  - clipboard support (select all <kbd>Ctrl+a</kbd>, <kbd>Ctrl+c/v/x</kbd>)

#### Filter mode

- live filtering by exif data or any other image info
- tab completion for image properties to filter by
- configurable display options - what to live-update (completion, images, filter list…)
- filtering by multiple metrics and operators
- default config and basic usage (see <./mode/filter.lua> for more details):
  ```lua
  local fm = require('sai.mode.filter').new {
  	_location = 'topleft',
  	-- Public, changeable at any time
  	update_imagelist_on_confirm = true, ---Should imagelist be set to filtered images
  	live_imagelist = true, ---Should imagelist be updated with filtering
  	live_pager = true, ---Should a pager with the filtered files be displayed
  	---Should a pager with completion for the current tag be visible
  	---`'i'` for matching with ignored casing
  	tag_completion = true, ---@type false|'i'|true
  }
  g.map('/', function() fm.enabled = true end)
  ```

### Custom default scaling modes

- `keep_xxx`:
  - keeps image view size constant (depending on chosen metric) regardless of image resolution
  - useful for comparing identical images of different sizes
  - you will stay zoomed into the same spot of the image even if the other image is half the
    resolution
  - `xxx` can be replaced with any of the default scaling names or `keep_size`
- add your own:

  ```lua
  table.insert(
    require('sai.api.viewer').custom_scale_handlers,
    ---@param self sai.api.viewer
    function(self, x)
      if type(x) ~= 'table' or not x.width or not x.height then return end

      e.subscribe {
        event = 'ImgChanged',
        match = 'viewer',
        callback = function(ev)
          if self._default_scale ~= x then return true end -- unsubscribe

          local img = ev.data or error()
          if x.width >= img.width and x.height >= img.height then return end

          local xscale = x.width / img.width
          local yscale = x.height / img.height
          self.super.set_abs_scale(math.min(xscale, yscale))
        end,
      }

      return 'real'
    end
  )
  v.default_scale = { width = 2560, height = 1440 }
  ```

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
- pretty print tables - replace default tostring() method for better table conversion
- command mode for live-executing lua with command history support
- two-pane mode for viewing images side-by-side

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
processes. Run it from anywhere:

```sh
luajit tests/init.lua                     # all tests
luajit tests/debug.lua                    # one module
luajit tests/init.lua debug.breakpoints   # one method
```

### TODOs

- way to fake partially enabled text layer (disable all besides the active one)
  - when disabled, enable text layer but hide all textfield layers with `{}`
  - pass sai faker (or real) to every component (or it creates its own reconfigurer by default)
    - that way one mode puts all its overrides into just one place that gets applied at once in the
      right order
  - use active_modes to determine which mode is above which other one and on disable of a mid-mode,
    if a mode above has changed the same var, then don't restore it, but set the backed value to the
    mode backer above
- clever state restoring by deciding what to override and what to keep based on active modes order
- make input mode into a simple utils function for requesting user input
- unify pager and input mode
- generalize completion in filter mode and filter mode itself (for filtering of any content)
- add another mode to filter variables and view and change their live values (like mpv `gv`)
- make it easier to make multi-level keybinds (like vim `cd/ce/cb…`)
- make a snippet for loading keybind config from ranger

## License

Do whatever you please but don't lie about what it is.
