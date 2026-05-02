# `swi.swi`

What's up with the name? You tell me:

- _SWayImg_ - just like `imv` is a shorthand of `IMageViewer`
- shorter and easier to type when accessing the api
- simple way to say a lua package is made for swayimg - like `.nvim` for neovim
- _Swayimg neoWim-like Interface_
  - allows vim-style mappings like `<C-S-Del>`, `<C-.>`…
  - eventloop system based on neovim lua autocommands - almost everything is listenable
  - variables are now all 2-way accessible variables, not just setter methods
- _Superb Wayland Imageviewer_
  - because swayimg is already _the_ waylang imager and this only makes it better
  - because the api is simpler and efficient, yet offers more features and practicality than the
    original

<details>
<summary>

## ✨ Complete list of Features

- All basic features that swayimg should have by default.
- Focus on extensibility and ease of use. (provides a convertor for old configs - 4.x)
- Provides all the basic api features that are necessary for creating more complex behaviour.

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
- **eventloop**: subscribe to any change in the api and trigger your own events for inter-module
  messaging
  - inspired by vim event structure and neovim for registering the hooks
- text layer templates:
  - track any api variable: `g.text.topright={'Marked: {swi.imagelist.marked.size}'}`
  - pretty-print exif data: `v.text.topleft={'Exposure: {ExposureTime}'}`
  - dynamic event updates - use eventloop hooks to update the text dynamically:
    ```lua
    v.text.topleft={
      {event='User',pattern='mymsg',function(ev)
        if not ev then return 'Ready to receive messages' end
        if type(ev.data) == 'table' then
          ev.data[1] = 'Received multiline:\t'..ev.data[1]
          return ev.data
        else
          return ev.data and ('Received multiline:\t' .. ev.data)
        end
      end}
      [100] = 'Surely the message is shorter than 100 lines and won\'t override this'
    }
    ```
- style-agnostic keybinds: use gui-, imv- or **vim-style** keybinds or any style that's right for
  you
  ```lua
  --        gui,      vim,    imv-gui,  chaos (please don't!)
  g.map({ 'Shift+m', '<S- >', 'Alt-h',   'C-S+Alt-_' }, function()
  	l.marked.set_current 'toggle'
  	g.go.left()
  end)
  ```
- map **shell commands** directly with **ranger-style** file placeholders:
  - `%f`: `'`-quoted current file: `v.map('Ctrl-e', 'xdg-open %f')`
  - `%s`/`%m`: `'`-quoted marked/selected files: `v.map('A-s', 'dragon-drop -x -A %s')`
    - useful mapping until we get an alternativ for dragging all marked files
    - `%s`: falls back to current file
    - `%m`: doesn't execute the command if no files were marked
  - `%`: unquoted current (like in 4.x): `v.map('', [[bash -c '$(which trash || echo rm) "%"']])`
- custom **help mode** that lets you see all available keybindings or settings
- **custom modes**: easily create custom modes that temporarily change the mappings, settings and
  even hooks
  ```lua
  v.map('a', function() swi.antialiasing = not swi.antialiasing end)
  v.map('s', require'swi.snippets'.cycle_scale)
  v.map('d', function() l.remove(l.get_current().path) end)
  -- create a custom mode override
  local x = require('swi.lib.mode_override').new { _path = 'panner', _auto_help = true }
  -- automatically disable on mode change (otherwise stays active in viewer mode)
  x.swi.eventloop.subscribe { event = 'ModeChangedPre', callback = function() x.enabled = false end }
  -- use the highest precission
  x.swi.viewer.pan.default_size = 1
  v.map('y', function() x.enabled = not x.enabled end, 'Toggle panning keybind mode')
  x.map('F1', function() x.help_pager.enabled = not x.help_pager.enabled end, 'Toggle this help')
  x.map('a', v.pan.left, 'Pan left') -- add description to show in help mode properly
  x.map('w', v.pan.up, 'Pan up')
  x.map('s', v.pan.down, 'Pan down')
  x.map('d', v.pan.right, 'Pan right')
  ```

### New scaling modes

- `keep_by_xxx`:
  - useful for comparing identical images of different sizes
  - you will stay zoomed into the same spot of the image even if the other image is half the
    resolution
  - available metrics: …`width`/`height`/`size` - like `width`/`height`/`optimal` scaling

### TODOs

- create PR to synchronize order of declaring variables/api to align with source code

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

### ⚠️ Limitations

True eventloop used by swayimg internally is still inaccessible. That means we cannot listen for
file updates and save image state (like scale, position, etc.) before the image gets changed.

</details>

## 🚀 Geting Started

Clone the repo into your swayimg config to `swi` _(not `swi.swi`!)_.

```sh
git clone https://github.com/litoj/swi ~/.config/swayimg/swi
```

_Don't forget to add it to `.gitignore`, if you version your dotfiles_

### 🏠 Keep and convert your 4.x INI config

```sh
luajit ~/.config/swayimg/swi/convertor.lua > ~/.config/swayimg/init.lua
```

Now you can open them side by side to see how the structure has changed.

If you want to keep using your old config, you can also load it on startup dynamically:

```lua
-- ~/.config/swayimg/init.lua
require('swi.convertor').load()
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
