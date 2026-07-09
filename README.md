# `swi.swi`

What's up with the name? You tell me:

- _SWayImg_ - just like `imv` is a shorthand of `IMageViewer`
- shorter and easier to type when accessing the api
- simple way to say a lua package is made for swayimg - like `.nvim` for neovim
- _Swayimg neoWim-like Interface_
  - allows vim-style mappings - `<C-S-Del>`, `<C-.>`…
  - eventloop system based on neovim lua autocommands - almost everything is listenable
  - all variables can now be set _and_ read - no more caching of the last set value
- _Superb Wayland Imageviewer_
  - because swayimg is already _the_ wayland imager and this only makes it better
  - because the api is simpler and efficient, yet offers more features and practicality than the
    original

<details>
<summary>

## ✨ Complete list of Features (_click to expand_)

- All basic features that swayimg should have by default.
- Focus on extensibility and ease of use.
- **Custom modes!** - exemplary usage of filtering mode:

https://github.com/user-attachments/assets/5b1e5b56-7f84-4525-b490-6ff0ff6a30be

</summary>

- options now accessible as variables: `swi.text.size = swi.text.size*1.1`
- forward compatible: original api is still directly forwarded through `swi` so all additions are
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
  - track any api variable: `g.text.topright={'Marked: {swi.imagelist.marked.size}'}`
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
    e.trigger{event='User', match='help', data=U.str_bindlist(swi.mode.input)}
    ```
- style-agnostic keybinds: use gui-, imv- or **vim-style** keybinds or any style that's right for
  you
  ```lua
  --        gui,      vim,    imv-gui, multi-click
  g.map({ 'Shift+m', '<S- >', 'Alt-h', 'C-2-LMB' }, function()
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

### Custom modes

- easily make temporary changes to anything in the api
- all changes are active only while the custom mode is enabled - see `snippets.two_pane_mode`
- make variable changes and optinally allow the user to adjust the user to adjust them
- automatic event subscriptions and deletions
- define custom keybinds with automatic help page displaying the keybinds

#### Sealed modes

These are modes that aren't meant to be extended or reused, they are just one singleton instance you
can configure.

- custom **help mode** that lets you see all available keybindings and live-updated settings
  <img width="1256" height="764" alt="Image of help mode in the settings section" src="https://github.com/user-attachments/assets/1393488e-a0ba-4bd4-8f9a-26c314ecb112" />
- **command mode** for live-evaluating lua code (example of extending **input mode**)
- **two-pane mode** for comparing images (limited by the gallery scaling implementation)

#### Input mode

- allows you to input arbitrary text and do whatever you want with it
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
  local fm = require('swi.mode.filter').new {
  	_location = 'topleft',
  	auto_help = true,
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
    require('swi.api.viewer').custom_scale_handlers,
    ---@param self swi.api.viewer
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

### TODOs

- create PR to synchronize order of declaring variables/api to align with source code
- create custom mode to dynamically pick which elements should be in each text corner

### [Snippets](./snippets.lua)

A collection of small code snippets that might be often wanted. Or can just serve as an inspiration
for your own scripts.

Snippets include:

- loading the current directory when swayimg opened with just 1 image
- printing a status message on every variable change (like it used to be)
- resizing the image with the window if the image is in not zoomed in
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

Clone the repo into your swayimg config to `swi` _(not `swi.swi`!)_.

```sh
git clone https://github.com/litoj/swi.swi ~/.config/swayimg/swi
```

_Don't forget to add it to `.gitignore`, if you version your dotfiles_

You can add a keybind to update swayimg:

```lua
v.map('Alt+F5', require('swi.snippets').update) -- for just viewer mode

local map = require 'swi.binds' -- for any mode combo
map('a', 'Alt+F5', require('swi.snippets').update)
```

### Use the API

To start using the api you only need to load the main module. However, if you also want to use all
the main APIs as globals, you can also load `swi.globals` to have easier access to them. The
structure is declared in [types.lua](./types.lua)

```lua
-- ~/.config/swayimg/init.lua
-- makes the api accessible through the `swi` global variable
-- you can also just save it to whatever you want
require 'swi.api.init'
-- or through first-letter globals (except: swi.imagelist -> `l` - not `i`)
require 'swi.api.globals'

-- now you can use all options as variables and make intricate behaviour using eventloop hooks
```

### Better dev experience in NeoVim

If you're already using _lua_ls_ you only need to include the original swayimg api definitions from
which _swi_ reuses the types:

```lua
settings.Lua.workspace.library = {'/usr/share/swayimg/swayimg.lua', '/usr/local/share/swayimg/swayimg.lua'}
```

## License

Do whatever you please.
