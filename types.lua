---@meta swi

--------------------------------------------------------------------------------
-- Main application class
--------------------------------------------------------------------------------

---Main application class.
---@class swi: swi.api.proxy
---@field mode appmode_t Which mode is the application in
---@field antialiasing boolean Enable/disable antialiasing
---@field exif_orientation boolean Enable or disable changing orientation based on EXIF
---@field apply_raw_wb boolean Should camera white balance be applied to raw images
---Enable or disable window decoration (title, border, buttons).
---Available only in Wayland, the corresponding protocol must be
---supported by the composer.
---By default disabled in Sway and enabled in other compositors.
---@field decoration boolean
---@field app_id string wayland application ID
---Create a floating window with the same coordinates and size as the currently
---focused window. This variable can be set only once.
---Sway and Hyprland compositors only.
---By default enabled in Sway and disabled in other compositors.
---@field overlay boolean
---@field fullscreen boolean set to `nil` to toggle
---Set mouse button used for drag-and-drop image file to external apps. (`MouseRight` etc.)
---Configurable only at startup.
---@field dnd_button string
---@field initialized boolean Whether initialization has completed and config has been loaded
---@field [appmode_t] mode_base
_G.swi = {}

---Execute a shell command in sync.
---Escape sequences:
--- - `%`: current file unquoted
--- - `%f`: current file quoted with singlequotes
--- - `%s`: all marked files or current file quoted with singlequotes
--- - `%m`: only marked files or don't execute
--- - `%%`: normal percentage sign (`%`)
---@see event.ShellCmdPost
---@param cmd string
---@return string stdout
---@return integer exitcode
function swi.exec(cmd) end

---Print a message on-screen.
---@see swi.text.set_status
---@param msg string
function swi.notify(msg) end

---Print a message on-screen and to the terminal
---@param msg string
function swi.log(msg) end

---Execute deferred procedure.
---@param seconds number Delay in seconds (can be fractional)
---@param fn function Function to execute
function swi.defer(seconds, fn) end

---Exit from application.
---NOTE: exits only if all SwiLeavePre hooks deregister!
---@param code? integer Program exit code, `0` by default
function swi.exit(code) end

---Get mouse pointer coordinates.
---@return { x :integer, y: integer } # Coordinates of the mouse pointer
function swi.get_mouse_pos() end

---Get application window size.
---@return { width: integer, height: integer } # Window size in pixels
function swi.get_window_size() end

---Set application window size.
---@param width integer Width of the window in pixels
---@param height integer Height of the window in pixels
function swi.set_window_size(width, height) end

--------------------------
--- Eventloop processing
--------------------------

---@class event.base
---@field event event_name_t
---@field mode? appmode_t|appmode_t[]
---@field match? string value the hooks should match against - describes the payload
---@field data? unknown observed object

---@alias event_name_t
---| 'ImgChanged' # after selected image has changed, match: mode, data: new image
---| 'ImgChangedPre' # just before selecting a different image, match: mode, data: old image
---| 'OptionSet' # after setting any option in the api, match: opt object path, data: opt value
---| 'ShellCmdPost' # after swi.exec, match: cmd, data: output
---| 'ModeChanged' # match: 'o:n' as in old:new, mode: new mode, data: old mode
---| 'ModeChangedPre' # match: 'o:n' as in old:new, mode: old mode, data: new mode
---| 'WinResized' # when a window is resized, data: new size
---| 'SwiEnter' # just after loading config and initializing imagelist
---| 'SwiLeavePre' # before exiting swayimg - hooks for given statuscode must deregister to exit
---| 'Signal' # USR1 or USR2 received by swayimg
---| 'Subscribed' # when a hook gets subscribed, match: event, mode: hook's mode, data: hook config
---| 'User' # custom user-emitted/triggered signaling

---@class hook.base
---@field event event_name_t|event_name_t[]
---@field mode? appmode_t|appmode_t[]
---@field group? string
---Simple string to match directly, luapat,
---or negated simple match ("!plainstr") to forbid that match
---@field pattern? string|string[]
---@field once? boolean should the hook be unsubscribed after first call
---@field callback fun(ev:swi.eventloop.event):(boolean?) return true to unsubscribe

do -- Event and Hook type definitions
	---@class event.ImgChanged: event.base
	---@field event 'ImgChanged'
	---@field match appmode_t
	---@field data swayimg.image

	---Hook for ImgChanged events
	---@class hook.ImgChanged: hook.base
	---@field event 'ImgChanged'
	---@field pattern? appmode_t|string[] prefer `pattern` over `mode` for better performance
	---@field callback fun(ev:event.ImgChanged):(boolean?)

	---@class event.ImgChangedPre: event.base
	---@field event 'ImgChangedPre'
	---@field match appmode_t
	---@field data swayimg.image

	---Hook for ImgChangedPre events
	---@class hook.ImgChangedPre: hook.base
	---@field event 'ImgChangedPre'
	---@field pattern? appmode_t|string[] prefer `pattern` over `mode` for better performance
	---@field callback fun(ev:event.ImgChangedPre):(boolean?)

	---@class event.OptionSet: event.base
	---@field event 'OptionSet'
	---@field match string option object path
	---@field data unknown option value

	---Hook for OptionSet events
	---@class hook.OptionSet: hook.base
	---@field event 'OptionSet'
	---@field callback fun(ev:event.OptionSet):(boolean?)

	---@class event.ShellCmdPost: event.base
	---@field event 'ShellCmdPost'
	---@field match string command that was executed
	---@field data? string command output

	---Hook for ShellCmdPost events
	---@class hook.ShellCmdPost: hook.base
	---@field event 'ShellCmdPost'
	---@field callback fun(ev:event.ShellCmdPost):(boolean?)

	---@alias mode_diff 'v:g'|'g:v'|'s:v'|'v:s'|'s:g'|'g:s' # 'old:new' format

	---@class event.ModeChanged: event.base
	---@field event 'ModeChanged'
	---@field match mode_diff
	---@field mode appmode_t new mode
	---@field data appmode_t old mode

	---Hook for ModeChanged events
	---@class hook.ModeChanged: hook.base
	---@field event 'ModeChanged'
	---@field pattern? mode_diff|string[]
	---@field mode appmode_t
	---@field callback fun(ev:event.ModeChanged):(boolean?)

	---@class event.ModeChangedPre: event.base
	---@field event 'ModeChangedPre'
	---@field match mode_diff
	---@field mode appmode_t old mode
	---@field data appmode_t new mode

	---Hook for ModeChangedPre events
	---@class hook.ModeChangedPre: hook.base
	---@field event 'ModeChangedPre'
	---@field pattern? mode_diff|string[]
	---@field mode appmode_t
	---@field callback fun(ev:event.ModeChangedPre):(boolean?)

	---@class event.WinResized: event.base
	---@field event 'WinResized'
	---@field data {width: integer, height: integer} new window size

	---Hook for WinResized events
	---@class hook.WinResized: hook.base
	---@field event 'WinResized'
	---@field callback fun(ev:event.WinResized):(boolean?)

	---@class event.SwiEnter: event.base
	---@field event 'SwiEnter'
	---@field match 'true'|'false' `initializing`: false during actual initialization, true otherwise

	---Hook for SwiEnter events
	---@class hook.SwiEnter: hook.base
	---@field event 'SwiEnter'
	---@field pattern? 'false' to run only on startup and be ignored otherwise
	---@field callback fun(ev:event.SwiEnter):(boolean?)

	---@class event.SwiLeavePre: event.base
	---@field event 'SwiLeavePre'
	---@field data integer exit status code

	---Hook for SwiLeavePre events
	---@class hook.SwiLeavePre: hook.base
	---@field event 'SwiLeavePre'
	---@field callback fun(ev:event.SwiLeavePre):(boolean?)

	---@class event.Signal: event.base
	---@field event 'Signal'
	---@field match 'USR1'|'USR2'

	---Hook for Signal events
	---@class hook.Signal: hook.base
	---@field event 'Signal'
	---@field pattern? 'USR1'|'USR2'|string[]
	---@field callback fun(ev:event.Signal):(boolean?)

	---@class event.Subscribed: event.base
	---@field event 'Subscribed'
	---@field match string event being subscribed to
	---@field mode appmode_t[] hook's mode
	---@field data swi.eventloop.hook hook config

	---Hook for Subscribed events
	---@class hook.Subscribed: hook.base
	---@field event 'Subscribed'
	---@field mode appmode_t[]
	---@field callback fun(ev:event.Subscribed):(boolean?)

	---@class event.User: event.base
	---@field event 'User'
	---@field match string custom match string

	---Hook for User events
	---@class hook.User: hook.base
	---@field event 'User'
	---@field callback fun(ev:event.User):(boolean?)

	---@class event.User.ExportFinished: event.User
	---@field event 'User'
	---@field match 'ExportFinished'
	---@field data string path of the exported file

	---Hook for User.ExportFinished events
	---@class hook.User.ExportFinished: hook.User
	---@field pattern? 'ExportFinished'|string[]
	---@field callback fun(ev:event.User.ExportFinished):(boolean?)

	---@alias swi.eventloop.event
	---| event.ImgChanged
	---| event.ImgChangedPre
	---| event.OptionSet
	---| event.ShellCmdPost
	---| event.ModeChanged
	---| event.ModeChangedPre
	---| event.WinResized
	---| event.SwiEnter
	---| event.SwiLeavePre
	---| event.Signal
	---| event.Subscribed
	---| event.User
	---| event.User.ExportFinished

	---@alias swi.eventloop.hook
	---| hook.base
	---| hook.ImgChanged
	---| hook.ImgChangedPre
	---| hook.OptionSet
	---| hook.ShellCmdPost
	---| hook.ModeChanged
	---| hook.ModeChangedPre
	---| hook.WinResized
	---| hook.SwiEnter
	---| hook.SwiLeavePre
	---| hook.Signal
	---| hook.Subscribed
	---| hook.User
	---| hook.User.ExportFinished
end

---@alias hook_id hook.base

---@class swi.eventloop.filter.opts
---@field event? event_name_t|event_name_t[]
---@field id? hook_id
---@field group? string|string[]
---@field mode? appmode_t|appmode_t[]
---@field match? string|string[]

---Eventloop processor
---@class swi.eventloop
---@field debug_trigger boolean print all triggered events and where they were triggered from
---@field debug_subscribe boolean print all hook registrations and where they were triggered from
swi.eventloop = {}

---@param hook swi.eventloop.hook
---@return hook_id id that can be used to remove the hook
function swi.eventloop.subscribe(hook) end

---@param f? swi.eventloop.filter.opts
---@return table<hook_id,swi.eventloop.hook>
function swi.eventloop.get_subscribed(f) end

---@param f swi.eventloop.filter.opts
function swi.eventloop.unsubscribe(f) end

---@param state swi.eventloop.event|event.base
function swi.eventloop.trigger(state) end

---Temporarily substitute all events matching the same conditions until self-deregistration.
---NOTE: can be undone only by the callback or with `once=true` - cannot use unsubscribe()
---@param cfg swi.eventloop.hook
function swi.eventloop.takeover_subscribe(cfg) end

--------------------------------------------------------------------------------
-- Image list
--------------------------------------------------------------------------------

---Image list
---Changes to the contents get emitted as OptionSet(`swi.imagelist.size`)
---@class swi.imagelist: swi.api.proxy
---@field order order_t Image list sort order
---@field reverse boolean Reverse the sort order
---@field recursive boolean Recursive directory reading
---@field adjacent boolean Open adjacent files from the same directory
---@field fsmon boolean Allow filesystem monitoring for changes and updating images
swi.imagelist = {}

do
	---Get current image entry (metadata is lazy-loaded)
	---@return swayimg.image
	function swi.imagelist.get_current() end

	---Get size of image list.
	---@return integer # Number of entries in the image list
	function swi.imagelist.size() end

	---Get list of all entries in the image list.
	---@return swayimg.entry[] # Array with all entries
	function swi.imagelist.get() end

	---Add entry to the image list.
	---@param paths string|string[] Paths to add
	function swi.imagelist.add(paths) end

	---Remove entry from the image list.
	---@param paths string|string[] Paths to remove
	function swi.imagelist.remove(paths) end

	---Helper for working with marks on images
	---Changes to the size get emitted as OptionSet(`swi.imagelist.marked.size`)
	---@class swi.imagelist.marked
	swi.imagelist.marked = {}

	---Get number of marked images.
	---@return integer
	function swi.imagelist.marked.size() end

	---Get list of all marked paths.
	---@return string[] paths of all marked images
	function swi.imagelist.marked.get() end

	---Toggle the marked state of the current entry.
	---@param state boolean|'toggle'
	function swi.imagelist.marked.set_current(state) end
end

--------------------------------------------------------------------------------
-- Text overlay layer
--------------------------------------------------------------------------------

---Text overlay layer.
---@class swi.text
---Should displaying the text layer be allowed,
---and how long for (after switching to a different image).
---Use `true` to disable timeout and permanently display, `false` to always hide, x for x seconds
---@field enabled boolean|number
---@field font string Font face name
---@field size integer Font size in pixels
---@field line_spacing number Factor of amount of space between lines (>0)
---@field padding integer Padding from window edges in pixels
---@field foreground integer Foreground text color in ARGB format, e.g. `0xff00aa99`
---@field background integer Background text color in ARGB format, e.g. `0xff00aa99`
---@field shadow integer Shadow text color in ARGB format, e.g. `0xff00aa99`
---@field status_timeout number Timeout in seconds after which the status message is hidden
swi.text = {}

---Get immediate visibility state of the text layer.
---@return boolean visible
function swi.text.is_visible() end

---Show status message for the duration of `swi.text.status_timeout` seconds.
---@param status string Status text to show
function swi.text.set_status(status) end

--------------------------------------------------------------------------------
-- Base mode class
--------------------------------------------------------------------------------

do
	---@class keybind_processor
	local keybind_processor = {}

	---Map a keyboard or mouse event to an action.
	---@param bind string|string[] 1 or more mouse or keyboard events to map - `Alt+s`, etc.
	---@param action fun()|string callback function to run or shell command to execute
	---@param opts bindcfg|string? optional description or other options for the keybind
	function keybind_processor.map(bind, action, opts) end

	---@class bindcfg
	---@field cb function|string the action that runs on the binding activation (or the shell command)
	---@field trace string where was the binding defined
	---@field desc? string optional description of the action
	---@field kind? 'default'|'private' what category does this bind belong to, unspecified is for user

	---@param bind string
	---@param bindcfg bindcfg config to set the bind to
	---@return bindcfg? old_bind previous config set for this binding
	function keybind_processor.remap(bind, bindcfg) end

	---@param bind string keybind to disable
	function keybind_processor.unmap(bind) end

	---@alias bind_map table<string,bindcfg>

	---@return bind_map map of the user bindings
	function keybind_processor.get_mappings() end

	---Extension to create event-based textlayer updates.
	---When triggered, the callback gets evaluated and value set to its position in the text block.
	---@class mode_base.text.dyntext: hook.base
	---@field group? nil This eventhook field gets set automatically for auto-deregistration
	---Generator of the text to be displayed.
	---NOTE: An initial call call without args is made to get the initial value of the text.
	---@field callback fun(ev:swi.eventloop.event|nil):(string|string[]?)

	---Extended text layer functionality for setting dynamic text values.
	---Multiline generators should remember the size of their previous output to reset the lines to ''
	---@alias extended_text_template
	---| text_template_t basic single-line template string
	---| mode_base.text.dyntext event-based generator
	---| fun(img:swayimg.image):(string|string[]?) generator for ImgChanged event

	---A more dynamic approach to updating the text layer.
	--- - custom functions to generate text on image change.
	--- - custom hooks to update the text when an event is triggered.
	---   - for tracking variables just template the varpath: `'Marked: {swi.imagelist.marked.size}'`
	---
	---In viewer+slideshow mode you can use exif tags directly, like {ExposureTime}
	---or specify the full exif path (without `meta.` prefix), like {Exif.Fujifilm.Rating}
	---`utils.format_exif` then automatically formats the values.
	---HINT: to see what tags are available: `print(swi.viewer.get_image().meta)`
	---@class mode_base.text
	---@field topleft extended_text_template[] Text layer scheme for top-left corner
	---@field topright extended_text_template[] Text layer scheme for top-right corner
	---@field bottomleft extended_text_template[] Text layer scheme for bottom-left corner
	---@field bottomright extended_text_template[] Text layer scheme for bottom-right corner

	---Base class providing text overlay layout fields shared by all display modes.
	---@class mode_base: keybind_processor,swi.api.proxy
	---@field text mode_base.text access to setting the overlay fields/indexes
	---@field mark_color integer Mark icon color in ARGB format
	---@field pinch_factor number how aggressive should the effect be
	---@field multiclick_delay number time for coupling mouse clicks as one mouse event (in seconds)
	local mode_base = {}

	---Reload current view. Causes ImgChanged event.
	---@param cb? fun() optional callback for action after the refresh
	function mode_base.reload(cb) end
end

--------------------------------------------------------------------------------
-- Viewer mode
--------------------------------------------------------------------------------

---Configuration for the grid pattern to be displayed for transparent image bg.
---@class checkerboard
---@field [1] integer first color (i.e. 0xff000000)
---@field [2] integer second color (i.e. 0xff888888)
---@field size integer size of individual grids in pixels

---@alias one_time_scale_t
---| "optimal" # 100% or less to fit to window
---| "width"   # Fit image width to window width
---| "height"  # Fit image height to window height
---| "fit"     # Fit to window
---| "fill"    # Crop image to fill the window

---@alias default_scale_t
---| one_time_scale_t
---| "real"    # Real size (100%)
---| "keep"    # Keep the same scale as for previously viewed image
---| "keep_width"  # Keep zoom level relative to image width
---| "keep_height" # Keep zoom level relative to image height
---| "keep_size"   # Keep zoom level relative to average of width and height
---| "keep_fit"    # Keep zoom level relative to
---| "keep_fill"   # Keep zoom level relative to image height

---@class swi.viewer.panner Move around the image with ready-to-map functions
---@field default_size integer Default size of the step to make (in pixels)
---@field by fun(x:integer,y:integer) Pan the image by x and y pixels in their directions
---@field left fun(p:integer?) Step left by `p` px (default: step.default_size)
---@field right fun(p:integer?) Step right by `p` px (default: step.default_size)
---@field down fun(p:integer?) Step down by `p` px (default: step.default_size)
---@field up fun(p:integer?) Step up by `p` px (default: step.default_size)

---@class swi.viewer : mode_base
---Helper table for easier mappings for moving around the image
---@see swi.viewer.switch_image Equivalent via passing a parameter
---@field pan swi.viewer.panner
---Helper table for easier mappings for switching between images
---@see swi.viewer.switch_image Equivalent via passing a parameter
---@field go {[vdir_t]:function}
---@field default_scale default_scale_t Default scale applied to newly opened images
---@field scale one_time_scale_t|number Scale of the image as a preset or absolute value
---@field default_position fixed_position_t Default position applied to newly opened images
---Position of the image relative to the position of the window.
---This is the viewport approach!
---Example: ←↑ corner of the image is outside the window -> `x,y<0`
---@field position fixed_position_t|{x:integer,y:integer}
---@field centering boolean should image be automatically centered when smaller than window size
---@field animation boolean State of the image (GIF) animation
---@field window_background integer|bkgmode_t Window background: solid ARGB color or fill mode
---Background color or pattern for transparent images (ARGB)
---@field image_background integer|checkerboard
---@field loop boolean Image list loop mode
---@field preload_limit integer Number of images to preload in a separate thread
---@field history_limit integer Number of previously viewed images to keep in cache
swi.viewer = {}

do
	---Add a file to the image list and select it.
	---@param path string Path to the file
	function swi.viewer.open(path) end

	---Open the next file in the specified direction.
	---@see swi.viewer.go equivalent using named methods for easier mapping
	---@param dir vdir_t Next file direction
	function swi.viewer.switch_image(dir) end

	---Get information about currently displayed image.
	---@return swayimg.image # Currently displayed image
	function swi.viewer.get_image() end

	---Set absolute image scale, scaling the change around a zoom center.
	---@param scale number Absolute value (1.0 = 100%)
	---@param x integer X coordinate of center point, empty for window center
	---@param y integer Y coordinate of center point, empty for window center
	function swi.viewer.scale_centered(scale, x, y) end

	---Get absolute image scale that the image is currently displayed at.
	---@return number
	function swi.viewer.get_abs_scale() end

	---Reset position and scale to default values.
	---@see swayimg.viewer.set_default_scale
	---@see swayimg.viewer.set_default_position
	function swi.viewer.reset() end

	---Show next frame from multi-frame image (animation).
	---This function stops the animation.
	---@return integer # Index of the currently shown frame
	function swi.viewer.next_frame() end

	---Show previous frame from multi-frame image (animation).
	---This function stops the animation.
	---@return integer # Index of the currently shown frame
	function swi.viewer.prev_frame() end

	---Flip image vertically.
	function swi.viewer.flip_vertical() end

	---Flip image horizontally.
	function swi.viewer.flip_horizontal() end

	---Rotate image.
	---@param angle rotation_t Rotation angle
	function swi.viewer.rotate(angle) end

	---Export currently displayed frame to PNG file.
	---@see event.User.ExportFinished
	---@param path string Path of the exported file
	function swi.viewer.export(path) end

	---Add/replace/remove meta info for currently displayed image.
	---@param key string Meta key name
	---@param value string Meta value, empty value to remove the record
	function swi.viewer.set_meta(key, value) end
end

--------------------------------------------------------------------------------
-- Slide show mode
--------------------------------------------------------------------------------

---@class swi.slideshow: swi.viewer
---@field timeout number Timeout in seconds after which the next image is opened
swi.slideshow = {}

--------------------------------------------------------------------------------
-- Gallery mode
--------------------------------------------------------------------------------

---@class swi.gallery: mode_base
---Helper table for easier mappings for switching between images
---@see swi.gallery.switch_image Equivalent via passing a parameter
---@field go {[gdir_t]:function}
---@field aspect aspect_t Thumbnail aspect ratio
---@field thumb_size integer Thumbnail size in pixels
---@field padding_size integer Padding between thumbnails in pixels
---@field border_size integer Border size for the selected thumbnail in pixels
---@field border_color integer Border color for the selected thumbnail in ARGB format
---@field selected_scale number Scale factor for the selected thumbnail (1.0 = 100%)
---@field selected_color integer Background color for the selected thumbnail in ARGB format
---@field unselected_color integer Background color for unselected thumbnails in ARGB format
---@field window_color integer Window background color in ARGB format
---@field preload boolean Preload invisible thumbnails
---@field hover boolean Update image selection with mouse movement
---@field cache_limit integer Max number of thumbnails stored in memory cache
---@field pstore boolean Persistent storage for thumbnails
---@field embedded_thumb boolean Use embedded thumbnails
---@field pstore_path string Custom path to the directory for persistent thumbnail storage
---Should thumbnails be reloaded when the smallest cached could be less than 1/2 resolution
---@field thumb_size_diff_reload boolean
swi.gallery = {}

---Select the next thumbnail from the gallery.
---@see swi.gallery.go equivalent using named methods for easier mapping
---@param dir gdir_t Next thumbnail direction
function swi.gallery.switch_image(dir) end

---Get information about currently selected image.
---@return swayimg.image # Currently selected image entry
function swi.gallery.get_image() end
