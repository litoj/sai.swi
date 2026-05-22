local exiv = require 'lib.exiv2_to_lua'

local function measure(cycle_count, paths)
	local total_time = 0
	for _ = 1, cycle_count do
		local start = os.clock()
		exiv.load_all(paths)
		local elapsed = os.clock() - start
		total_time = total_time + elapsed

		for _, entry in ipairs(paths) do
			entry.meta = nil
		end
	end
	return total_time * 1000
end

local function print_stats(fetch_count, total_time)
	print(string.format('Total: %.1f s\tf/ms: %.2f', total_time / 1000, fetch_count / total_time))
end

local HOME = os.getenv 'HOME'
local function test_directory(cycle_count, dir_path)
	local handle = io.popen(string.format('find %s -type f', dir_path:gsub('^~', HOME)))
	local paths = {}
	if handle then
		for line in handle:lines() do
			paths[#paths + 1] = { path = line }
		end
		handle:close()
	end
	if #paths == 0 then error('No files found in directory: ' .. dir_path) end

	return #paths, measure(cycle_count, paths)
end

local function test_multiple(cycle_count, dir_paths)
	local total_time = 0
	local total_fetches = 0

	for _, dir_path in ipairs(dir_paths) do
		local path_count, time = test_directory(cycle_count, dir_path)
		total_time = total_time + time
		print_stats(cycle_count * path_count, time)
		total_fetches = total_fetches + cycle_count * path_count
		cycle_count = cycle_count / 2
	end

	print_stats(total_fetches, total_time)
end

local count = tonumber(os.getenv 'COUNT') or 100

test_multiple(count, #arg > 0 and arg or {
	'/tmp/small',
	'/tmp/screen',
	'/tmp/sdcard',
})
