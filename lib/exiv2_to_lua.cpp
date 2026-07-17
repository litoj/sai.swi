// EXIF data extraction module for Lua using Exiv2.
#include <exiv2/metadatum.hpp>
#include <luajit-2.1/lua.hpp>

#include <exiv2/exiv2.hpp>

#include <cstdio>
#include <string>
#include <thread>
#include <vector>

constexpr static bool should_include(const Exiv2::Metadatum &item) {
	// Explicitly exclude binary and complex types that contain non-human-readable
	// data
	switch (item.typeId()) {
		case Exiv2::undefined: // Raw binary data (e.g., maker notes, profiles)
		case Exiv2::directory: // CIFF directory structure
		case Exiv2::xmpText: // XMP metadata (complex XML structure)
		case Exiv2::xmpAlt:
		case Exiv2::xmpBag:
		case Exiv2::xmpSeq:
		case Exiv2::langAlt:
		case Exiv2::tiffIfd:
		case Exiv2::tiffIfd8: //
			return false;
		default:
			// exclude hex key names
			return item.key().find(".0x") == std::string::npos;
	}
}

static void
populate_exif_table(lua_State *L, const std::vector<std::pair<std::string, std::string>> &meta) {
	lua_createtable(L, 0, 0);
	for (const auto &[k, v] : meta) {
		lua_pushlstring(L, k.c_str(), k.size());
		lua_pushlstring(L, v.c_str(), v.size());
		lua_settable(L, -3);
	}
}

static std::vector<std::pair<std::string, std::string>> read_image_meta(const std::string &path) {
	try {
		Exiv2::Image::UniquePtr exiv2 = Exiv2::ImageFactory::open(path);

		if (!exiv2) return {};

		exiv2->readMetadata();

		std::vector<std::pair<std::string, std::string>> meta;
		meta.reserve(exiv2->exifData().count() + exiv2->iptcData().count() + exiv2->xmpData().count());

		for (const auto &it : exiv2->exifData())
			if (should_include(it)) meta.push_back(std::make_pair(it.key(), it.value().toString()));

		for (const auto &it : exiv2->iptcData())
			if (should_include(it)) meta.push_back(std::make_pair(it.key(), it.value().toString()));

		for (const auto &it : exiv2->xmpData())
			if (should_include(it)) meta.push_back(std::make_pair(it.key(), it.value().toString()));

		return meta;
	} catch (const std::exception &) {
		return {};
	}
}

static int lua_get_meta(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	if (!path) luaL_error(L, "Expected string argument for path");

	populate_exif_table(L, read_image_meta(path));
	return 1;
}

static int lua_load_all(lua_State *L) {
	size_t count        = lua_objlen(L, 1);
	size_t thread_count = std::min(
	  static_cast<size_t>(std::thread::hardware_concurrency()),
	  (count + 7) / 8 // minimize thread overhead for low query size
	);

	std::vector<std::thread> threads;
	threads.reserve(thread_count);

	std::mutex mt;
	for (size_t t = 0; t < thread_count; t++) {
		threads.emplace_back([&, t]() {
			size_t l_idx = t + 1;
			while (l_idx <= count) {
				mt.lock();
				lua_rawgeti(L, -1, l_idx);

				lua_getfield(L, -1, "path");
				const char *path_str = lua_tostring(L, -1);
				std::string path(path_str);

				lua_pop(L, 2);
				mt.unlock();

				auto exif_data = read_image_meta(path);

				mt.lock();
				lua_rawgeti(L, -1, l_idx);

				populate_exif_table(L, exif_data);
				lua_setfield(L, -2, "meta");

				lua_pop(L, 1);
				mt.unlock();

				l_idx += thread_count;
			}
		});
	}

	for (auto &thr : threads) {
		thr.join();
	}

	return 0;
}

extern "C" int luaopen_exiv2_to_lua(lua_State *L) {
	lua_createtable(L, 0, 2);

	lua_pushcfunction(L, lua_get_meta);
	lua_setfield(L, -2, "get_meta");

	lua_pushcfunction(L, lua_load_all);
	lua_setfield(L, -2, "load_all");

	return 1;
}
extern "C" int luaopen_lib_exiv2_to_lua(lua_State *L) {
	return luaopen_exiv2_to_lua(L);
}

extern "C" int luaopen_sai_lib_exiv2_to_lua(lua_State *L) {
	return luaopen_exiv2_to_lua(L);
}
