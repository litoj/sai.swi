---Tests for sai.bridge.exiv2: the mtime-guarded meta cache.
---Needs the compiled exiv2 bridge; works on fixture copies in /tmp.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local T = {}

-- the cache keys on path but validates mtime: same mtime hits, changed
-- mtime re-reads the file instead of serving stale meta
T.mtime_guards_the_cache = function(h)
	local src = assert(io.open(H.dir .. '/fixtures/filter_canon1.jpg', 'rb'))
	local data = src:read '*a'
	src:close()
	local tmp = os.tmpname() .. '.jpg'
	local ran, err = pcall(function()
		local w = assert(io.open(tmp, 'wb'))
		w:write(data)
		w:close()

		local exiv2 = require 'sai.bridge.exiv2'
		local e1 = { path = tmp, mtime = 1000 }
		exiv2.add_meta(e1)
		h.eq('canon make loads', 'Canon', e1.meta['Exif.Image.Make'])

		local e2 = { path = tmp, mtime = 1000 }
		exiv2.add_meta(e2)
		h.ok('same mtime served from cache', e2.meta == e1.meta)

		local e3 = { path = tmp, mtime = 2000 }
		exiv2.add_meta(e3)
		h.ok('changed mtime re-read', e3.meta ~= e1.meta)
		h.eq('re-read value kept', 'Canon', e3.meta['Exif.Image.Make'])
	end)
	os.remove(tmp)
	if not ran then error(err, 0) end
end

-- load_all fills everything not yet cached: a pre-warmed path hits, a
-- new path reads once; nothing ever reads twice
T.load_all_obeys_the_same_cache = function(h)
	local exiv2 = require 'sai.bridge.exiv2'
	local tmp1 = '/tmp/sai-loadall-c1.jpg'
	local tmp2 = '/tmp/sai-loadall-flat.jpg'
	local tmp3 = '/tmp/sai-loadall-missing.jpg'
	os.remove(tmp1)
	os.remove(tmp3)
	H.exec(('cp %q %q'):format(H.dir .. '/fixtures/filter_canon1.jpg', tmp1))
	H.exec(('cp %q %q'):format(H.dir .. '/fixtures/filter_plain.png', tmp2))
	local ran, err = pcall(function()
		local cachewarm = { path = tmp1, mtime = 1 }
		exiv2.add_meta(cachewarm) -- pre-fill the cache like an earlier read
		h.eq('cache warm-up loads the make', 'Canon', cachewarm.meta['Exif.Image.Make'])

		local warm = { path = tmp1, mtime = 1 }
		local fresh = { path = tmp2, mtime = 1 }
		exiv2.load_all { warm, fresh }
		h.ok('the cached path takes from cache', warm.meta == cachewarm.meta)
		h.ok('the plain image got its dimensions', fresh.width ~= nil and fresh.height ~= nil)

		exiv2.load_all {} -- nothing staged: must be a silent silent no-op
		h.pass 'an empty batch passes'

		local missing = { path = tmp3, mtime = 1 }
		exiv2.add_meta(missing)
		-- an unreadable path yields an empty meta, never an error: callers
		-- indexing meta[tag] just get nil
		h.eq('a missing file runs silent with empty meta', nil, missing.meta and next(missing.meta))
	end)
	os.remove(tmp1)
	os.remove(tmp2)
	os.remove(tmp3)
	if not ran then error(err, 0) end
end

H.maybe_standalone(T)

return T
