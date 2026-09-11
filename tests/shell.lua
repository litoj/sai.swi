---Tests for sai.bridge.shell command expansion: placeholder quoting.
---Runs over a recording api stack (expansion reads the imagelist).
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local with_env = env.with_env
local S = require 'sai.bridge.shell'

-- the recording double stats entries on reads: back the paths with real
-- (empty) files so the run stays quiet
local function touch(paths)
	for _, p in ipairs(paths) do
		local f = assert(io.open(p, 'w'))
		f:close()
	end
end

local function wipe(paths)
	for _, p in ipairs(paths) do
		os.remove(p)
	end
end

local T = {}

-- single-quote wrapping must escape ticks, or filenames break the shell
T.quote_escapes_ticks = function(h)
	h.eq('plain value wraps in quotes', "'ab'", S.quote 'ab')
	h.eq('embedded tick escapes', "'a'\\''b'", S.quote "a'b")
end

T.placeholders_quote_paths = with_env(function(h)
	local paths = { "/tmp/sai-shell-a'b.jpg", '/tmp/sai-shell-plain.jpg' }
	touch(paths)
	local ran, err = pcall(function()
		local l = env.sai.imagelist
		l.clear()
		l.add(paths)
		l.select(paths[1])

		h.eq('%f quotes the file', "xdg-open '/tmp/sai-shell-a'\\''b.jpg'", S.parse_shell_cmd 'xdg-open %f')
		h.eq('lone %f expands quoted', "'/tmp/sai-shell-a'\\''b.jpg'", S.parse_shell_cmd '%f')

		l.marked.add(paths)
		-- the marks reach %s only in gallery mode; a viewer passes just the
		-- current file instead
		env.sai.mode = 'viewer'
		h.eq('the viewer passes the current file', "dragon '/tmp/sai-shell-a'\\''b.jpg'", S.parse_shell_cmd 'dragon %s')

		env.sai.mode = 'gallery'
		local expanded = S.parse_shell_cmd 'dragon %s'
		h.contains('first mark expands quoted', expanded, "'/tmp/sai-shell-a'\\''b.jpg'")
		h.contains('second mark expands quoted', expanded, "'/tmp/sai-shell-plain.jpg'")
		env.sai.mode = 'viewer'
	end)
	wipe(paths)
	if not ran then error(err, 0) end
end)

T.unmarked_m_errors = with_env(function(h)
	env.sai.imagelist.clear() -- marks of the other tests must not leak in
	local ran = pcall(S.parse_shell_cmd, 'dragon %m')
	h.ok('no marks aborts the command', not ran)
end)

T.percent_escapes = with_env(function(h)
	env.sai.imagelist.clear()
	env.sai.imagelist.add { '/tmp/sai-shell-plain.jpg' }
	h.eq('double percent stays one', '100% sure', S.parse_shell_cmd '100%% sure')
end)

-- bare expressions gain a return, explicit returns stay, bad code
-- reports a syntax error instead of a runnable
T.make_runnable_round_trip = function(h)
	local run, err = S.make_runnable '1 + 1'
	h.eq('valid chunk builds without error', nil, err)
	h.eq('bare expression returns', 2, run())

	local kept = assert(S.make_runnable 'local a = 1 return a + 1')
	h.eq('explicit return kept', 2, kept())

	local bad, berr = S.make_runnable '{{{'
	h.eq('syntax error: no runnable', nil, bad)
	h.contains('the syntax error names its input chunk', berr or '', 'input:1:')
end

-- the declared params arrive as locals: the caller passes their values
T.make_runnable_params = function(h)
	local run = assert(S.make_runnable('self', { 'self' }))
	h.eq('the value lands in the named local', 'me', run 'me')
	h.eq('no self global behind the local', nil, rawget(_G, 'self'))

	local add = assert(S.make_runnable('a + b', { 'a', 'b' }))
	h.eq('every param passes in order', 3, add(1, 2))
	h.eq('no param global behind the local', nil, rawget(_G, 'a'))

	local throwing = assert(S.make_runnable 'error("kaboom")')
	h.ok('a plain chunk still throws', not pcall(throwing))
end

H.maybe_standalone(T)

return T
