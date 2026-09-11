---@module 'sai.lib.ui'

local editor = require 'sai.mode.editor'
local selector = require 'sai.mode.selector'

---One-shot user prompts over editor/selector modes; anything more involved: build the modes directly.
---Two styles: callback (`on_confirm` given, async) and sync (parks in a coroutine.wrap()ped fn, returns the verdict).
---@class sai.lib.ui
local M = {
	---status fits one line
	---@type text_location
	input_location = 'status',
	---@type text_location
	select_location = 'topleft',
}

---The `on_confirm` hook of a parked sync call: resumes the caller exactly
---once; errors surface at the confirming keypress, like a bind error.
---@generic R
---@param co thread
---@return fun(_:sai.mode.editor|sai.mode.selector<unknown>, result:R)
local function resumable(co)
	local done = false
	return function(_, result)
		if done then return end
		done = true
		local ok, err = coroutine.resume(co, result or false)
		if not ok then error(err, 0) end
	end
end

---The user-facing hooks take the value only; the mode hooks get (self, value).
---@class sai.lib.ui.input_opts
---@field prompt? string
---@field on_confirm? fun(text:string[]|false) async verdict hook; absent parks the caller (sync style)
---@field on_text_changed? fun(text:string)
---@field location? text_location
---@field text? string initial input content

---@param opts sai.lib.ui.input_opts
---@return string[]|false|sai.mode.editor the verdict (sync style), or the enabled editor (callback style)
function M.input(opts)
	opts = opts or {}
	local cfg = {}
	cfg._prompt = opts.prompt or ''
	cfg._location = opts.location or M.input_location
	cfg.on_text_changed = opts.on_text_changed and function(_, text) opts.on_text_changed(text) end

	local co = not opts.on_confirm and coroutine.running()
	if not opts.on_confirm and not co then error('run in coroutine.wrap()ped fn or provide on_confirm', 2) end
	cfg.on_confirm = co and resumable(co) or function(_, text) opts.on_confirm(text) end

	local inst = editor.new(cfg)
	if opts.text then inst.text = opts.text end
	inst.unmap 'Ctrl+Escape'
	inst.map('Ctrl+Escape', function() inst:confirm(false) end, 'Abort input')
	inst.enabled = true
	if co then return coroutine.yield() end
	return inst
end

---The user-facing hook takes the values only, not the selector.
---@class sai.lib.ui.select_opts<I>
---@field prompt? string title shown above the list
---@field lines? `I`[]
---@field line_fmt? fun(selector:sai.mode.selector<I>, item:I, idx:integer):string paints one row; a hook that needs the live state reads it off the selector
---@field on_confirm? fun(result:I|I[]|false) async verdict hook; absent parks the caller (sync style)
---@field location? text_location

---Marked come back in marking order.
---@generic I
---@param opts sai.lib.ui.select_opts<I>
---@return I|I[]|false|sai.mode.selector the verdict (sync style), or the enabled selector mode (callback style)
function M.select(opts)
	opts = opts or {}

	local co = not opts.on_confirm and coroutine.running()
	if not opts.on_confirm and not co then error('run in coroutine.wrap()ped fn or provide on_confirm', 2) end

	local sel = selector.new {
		_path = 'sai.mode.ui',
		title = opts.prompt or '',
		_location = opts.location or M.select_location,
		on_confirm = co and resumable(co) or function(_, result) opts.on_confirm(result) end,
	}

	sel.lines = opts.lines or {}
	if opts.line_fmt then sel.line_fmt = opts.line_fmt end

	sel.unmap 'Ctrl+Escape'
	sel.map('Ctrl+Escape', function() sel:confirm(false) end, 'Abort selection')
	sel.enabled = true
	if co then return coroutine.yield() end
	return sel
end

return M
