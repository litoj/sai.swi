---Tests for sai.mode.tag_edit: the two states (tag pick, value set), the
---completion swap between their grounds, the dotless fan-out, the exiv2
---write/delete and the meta patch of the written files.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.tag_edit' }
local with_env = env.with_env
local il = env.sai.imagelist

-- committed binaries carrying Make/Model/ExposureTime tags (plus one
-- tagless file): Make dedups to two values, ExposureTime to three; the
-- fan-out fixture carries one leaf in two families (Exif.Image, Exif.Photo)
local function fx(name) return H.dir .. '/fixtures/' .. name end
local function fixtures()
	return { fx 'filter_canon1.jpg', fx 'filter_canon2.jpg', fx 'filter_nikon.jpg', fx 'filter_plain.png' }
end

-- public-api setup; current is the first entry (the app displays it)
local function install_imagelist(entries)
	il.clear()
	il.add(entries)
end

-- the completion pane (tag pool or values) in display order
local function pane(m)
	local out = {}
	for _, it in ipairs(m.completion.lines) do
		out[#out + 1] = it.text or it
	end
	return table.concat(out, '\n')
end

-- the exec runs get stubbed: a list serves one entry per call, a single
-- table every call; the tests assert the command, not the write
local function stub_exec(result)
	local cmds = {}
	local seq = result[1] and result or { result }
	local i = 0
	env.sai.exec = function(cmd)
		cmds[#cmds + 1] = cmd
		i = math.min(i + 1, #seq)
		local r = seq[i]
		return r.out or '', r.code, r.err or ''
	end
	return cmds
end

local T = {}

-- The pool holds the meta tags only: no path, size or other list fields.
T.pool_lists_meta_tags = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	h.eq('the status bar holds the prompt and the input', 'Tag: ▎', env.swayimg.text.status)
	h.eq(
		"the pool shows each tag with the current image's value",
		'Exif.Image.ExifTag:\t64\nExif.Image.Make:\tCanon\nExif.Image.Model:\tEOS 5D\nExif.Photo.ExposureTime:\t1/250',
		pane(m)
	)

	m.text = 'Exposure'
	h.eq('typing narrows the pool', 'Exif.Photo.ExposureTime:\t1/250', pane(m))
	m.text = 'make'
	h.eq('an all-lowercase input folds the case', 'Exif.Image.Make:\tCanon', pane(m))
	m.text = 'Exif.Image'
	h.eq(
		'a dotted input runs against the full path',
		'Exif.Image.Make:\tCanon\nExif.Image.Model:\tEOS 5D\nExif.Image.ExifTag:\t64',
		pane(m)
	)
	m.text = 'zzz'
	h.eq('no match: the pool empties', '', pane(m))
	m.text = ''
	h.eq(
		'cleared input: the whole pool back',
		'Exif.Image.ExifTag:\t64\nExif.Image.Make:\tCanon\nExif.Image.Model:\tEOS 5D\nExif.Photo.ExposureTime:\t1/250',
		pane(m)
	)

	m:confirm(false)
end)

-- Tab registers the tag under the cursor: the completion swaps to the tag's
-- deduplicated values, Tab there completes into the input.
T.tab_swaps_to_the_values = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	m.text = 'Make'
	env.raw_binds['viewer:Tab']()
	h.eq('the tag under the cursor is picked', 'Exif.Image.Make', m._tag)
	h.eq('the input clears after the pick', '', m.text)
	h.eq('the prompt names the picked tag', 'Set Exif.Image.Make: ▎', env.swayimg.text.status)
	h.eq('the values dedup across the images, sorted', 'Canon\nNikon', pane(m))

	m.text = 'Ca'
	h.eq('typing narrows the values', 'Canon', pane(m))
	env.raw_binds['viewer:Tab']()
	h.eq('Tab completes the value into the input', 'Canon', m.text)

	m:confirm(false)
end)

-- Enter in the pick state confirms the typed text as the tag: no completion
-- fill-in, a dotless name fans out to every loaded key with that leaf.
T.enter_picks_the_typed_tag = with_env(function(h)
	install_imagelist(fixtures())
	local cmds = stub_exec { code = '0' }
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	m.text = 'Model'
	local recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.eq('the typed text is the tag, not the candidate', 'Model', m._tag)
	h.eq('a dotless name expands to the matching key', 'Exif.Image.Model', table.concat(m._keys, '\n'))
	h.eq('the values follow the expanded keys', 'EOS 5D', pane(m))
	h.contains('the pick warning comes from the mode', recs[1].trace, 'mode/tag_edit.lua')
	h.ok('the mode stays open', m.enabled)

	-- a partial word takes no candidate either: a missless leaf targets the Exif family
	env.raw_binds['viewer:Escape']()
	m.text = 'Mak'
	env.raw_binds['viewer:Return']()
	h.eq('a partial word stays as typed', 'Mak', m._tag)
	h.eq('the missless leaf falls back to the Exif family', 'Exif.Image.Mak', table.concat(m._keys, '\n'))
	h.eq('no write command ran', 0, #cmds)
end)

-- A dotless leaf that lives in two families fans the write out to both.
T.dotless_fans_out = with_env(function(h)
	install_imagelist { fx 'filter_canon1.jpg', fx 'tag_edit_fanout.jpg' }
	local cmds = stub_exec { code = '0' }
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	h.eq(
		'both DateTimeOriginal keys sit in the pool',
		'Exif.Image.DateTimeOriginal\nExif.Image.ExifTag:\t64\nExif.Image.Make:\tCanon\nExif.Image.Model:\tEOS 5D\nExif.Photo.DateTimeOriginal\nExif.Photo.ExposureTime:\t1/250',
		pane(m)
	)

	m.text = 'DateTimeOriginal'
	env.raw_binds['viewer:Return']()
	h.eq('the typed leaf is the tag', 'DateTimeOriginal', m._tag)
	h.eq(
		'the leaf expands to every loaded key, sorted',
		'Exif.Image.DateTimeOriginal\nExif.Photo.DateTimeOriginal',
		table.concat(m._keys, '\n')
	)
	h.eq('the values come from both keys', '2024:01:01 10:20:30', pane(m))

	m.text = '2025:06:07 08:09:10'
	env.raw_binds['viewer:Return']()
	h.eq('the write command ran once', 1, #cmds)
	h.eq(
		'one -M per expanded key',
		"exiv2 -M'set Exif.Image.DateTimeOriginal 2025:06:07 08:09:10' -M'set Exif.Photo.DateTimeOriginal 2025:06:07 08:09:10' %f",
		cmds[1]
	)

	-- the current image (the first entry) mirrors both keys
	h.eq(
		'the image DateTimeOriginal mirrors the write',
		'2025:06:07 08:09:10',
		il.get(true)[1].meta['Exif.Image.DateTimeOriginal']
	)
	h.eq(
		'the photo DateTimeOriginal mirrors the write',
		'2025:06:07 08:09:10',
		il.get(true)[1].meta['Exif.Photo.DateTimeOriginal']
	)
end)

-- Enter with the tag picked writes the value through sai.exec and closes.
T.write = with_env(function(h)
	install_imagelist(fixtures())
	local cmds = stub_exec { code = '0' }
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	m.text = 'Make'
	env.raw_binds['viewer:Tab']()
	m.text = 'Pentax'
	local recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)

	h.eq('the write command ran once', 1, #cmds)
	h.eq(
		'the command writes the tag, the current file for sai.exec',
		"exiv2 -M'set Exif.Image.Make Pentax' %f",
		cmds[1]
	)
	h.ok('the mode closed after the write', not m.enabled)
	h.contains('the closing message comes from the mode', recs[1].trace, 'mode/tag_edit.lua')

	-- the current image (the first entry) mirrors the write
	h.eq('the written value lands in the current entry', 'Pentax', il.get(true)[1].meta['Exif.Image.Make'])
	h.eq('the other entries keep their values', 'Canon', il.get(true)[2].meta['Exif.Image.Make'])
end)

-- Marked files take the write: `%m` carries them, only their entries mirror it.
T.write_marked = with_env(function(h)
	install_imagelist(fixtures())
	local cmds = stub_exec { code = '0' }
	il.marked.add { fx 'filter_canon2.jpg', fx 'filter_nikon.jpg' }

	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	m.text = 'Make'
	env.raw_binds['viewer:Tab']()
	m.text = 'Pentax'
	env.raw_binds['viewer:Return']()

	h.eq('the command ran once', 1, #cmds)
	h.eq('the marked files ride the command', "exiv2 -M'set Exif.Image.Make Pentax' %m", cmds[1])
	h.eq('the marked canon entry mirrors the write', 'Pentax', il.get(true)[2].meta['Exif.Image.Make'])
	h.eq('the marked nikon entry mirrors the write', 'Pentax', il.get(true)[3].meta['Exif.Image.Make'])
	h.eq('the unmarked current entry keeps its value', 'Canon', il.get(true)[1].meta['Exif.Image.Make'])
end)

-- Both writers refuse: the fallback output reaches the message, the mode
-- stays open with its picked tag.
T.write_failure_keeps_state = with_env(function(h)
	install_imagelist(fixtures())
	local cmds = stub_exec {
		{ code = '1', err = 'Writing to BMFF images is not supported' },
		{ code = '1', err = 'exiftool boom' },
	}
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	m.text = 'Make'
	env.raw_binds['viewer:Tab']()
	m.text = 'Pentax'
	local recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)

	h.eq('both writers ran', 2, #cmds)
	h.ok('the mode stays open', m.enabled)
	h.eq('the picked tag stays', 'Exif.Image.Make', m._tag)
	h.contains('the fallback failure message comes from the mode', recs[1].trace, 'mode/tag_edit.lua')
	h.eq('no meta patch on failure', 'Canon', il.get(true)[1].meta['Exif.Image.Make'])

	-- a silent failure falls back to stdout
	stub_exec {
		{ code = '1', out = 'Uncaught exception: bogus' },
		{ code = '1', out = 'exiftool nothing' },
	}
	m.text = 'Pentax'
	recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.contains('the fallback stdout message comes from the mode', recs[1].trace, 'mode/tag_edit.lua')
end)

-- exiv2 refuses the whole format (BMFF images: jxl, avif): exiftool takes
-- the write with the mapped keys.
T.fallback_write_on_format_refusal = with_env(function(h)
	install_imagelist(fixtures())
	local cmds = stub_exec {
		{ code = '1', err = 'Writing to BMFF images is not supported' },
		{ code = '0' },
	}
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	m.text = 'Make'
	env.raw_binds['viewer:Tab']()
	m.text = 'Pentax'
	local recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)

	h.eq('both writers ran', 2, #cmds)
	h.eq('exiv2 ran first', "exiv2 -M'set Exif.Image.Make Pentax' %f", cmds[1])
	h.eq('the keys map to exiftool groups', "exiftool -n -overwrite_original '-Exif:IFD0:Make=Pentax' %f", cmds[2])
	h.ok('the mode closed after the fallback write', not m.enabled)
	h.contains('the closing message comes from the mode', recs[1].trace, 'mode/tag_edit.lua')
	h.eq('the written value lands in the current entry', 'Pentax', il.get(true)[1].meta['Exif.Image.Make'])
end)

-- An empty value warns first; the second Enter deletes the tag, typing
-- disarms the deletion again.
T.empty_value_deletes_on_double_enter = with_env(function(h)
	install_imagelist(fixtures())
	local cmds = stub_exec { code = '0' }
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	m.text = 'Make'
	env.raw_binds['viewer:Tab']()

	local recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.eq('nothing ran on the first Enter', 0, #cmds)
	h.ok('the mode stays open', m.enabled)
	h.contains('the first Enter warning comes from the mode', recs[1].trace, 'mode/tag_edit.lua')

	-- typing after the warning disarms the deletion
	m.text = 'x'
	m.text = ''
	recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.contains('the emptied input warns again from the mode', recs[1].trace, 'mode/tag_edit.lua')
	h.eq('still no write command ran', 0, #cmds)

	recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.eq('the deletion command ran once', 1, #cmds)
	h.eq('the command deletes the tag', "exiv2 -M'del Exif.Image.Make' %f", cmds[1])
	h.ok('the mode closed after the deletion', not m.enabled)
	h.contains('the closing message comes from the mode', recs[1].trace, 'mode/tag_edit.lua')
	h.eq('the key left the current entry', nil, il.get(true)[1].meta['Exif.Image.Make'])
end)

-- The first Escape drops the picked tag back to the pool; the second aborts.
T.escape_drops_back_then_aborts = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.tag_edit'].new { _path = 'sai.mode.tag_edit' }
	m.enabled = true

	m.text = 'Make'
	env.raw_binds['viewer:Tab']()
	h.eq('the values complete while the tag is picked', 'Canon\nNikon', pane(m))

	env.raw_binds['viewer:Escape']()
	h.eq('the picked tag dropped', false, m._tag)
	h.eq(
		'the tag pool restored',
		'Exif.Image.ExifTag:\t64\nExif.Image.Make:\tCanon\nExif.Image.Model:\tEOS 5D\nExif.Photo.ExposureTime:\t1/250',
		pane(m)
	)
	h.eq('the tag prompt restored', 'Tag: ▎', env.swayimg.text.status)
	h.eq('the input back to empty', '', m.text)

	env.raw_binds['viewer:Escape']()
	h.ok('the second Escape aborts the mode', not m.enabled)
end)

H.maybe_standalone(T)

return T
