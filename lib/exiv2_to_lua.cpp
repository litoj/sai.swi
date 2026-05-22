// EXIF data extraction module for Lua using Exiv2.
#include <luajit-2.1/lua.hpp>

#include <exiv2/exiv2.hpp>

#include <cstdio>
#include <string>
#include <thread>
#include <vector>

/**
 * Check if an EXIF value should be included based on its type.
 * This filters out complex/binary data like lens correction profiles,
 * keeping only human-readable values (strings, numbers, rationals).
 */
constexpr static bool should_include_type(Exiv2::TypeId type) {
	// Explicitly exclude binary and complex types that contain non-human-readable
	// data
	switch (type) {
		case Exiv2::undefined: // Raw binary data (e.g., maker notes, profiles)
		case Exiv2::directory: // CIFF directory structure
		case Exiv2::xmpText: // XMP metadata (complex XML structure)
		case Exiv2::xmpAlt: // XMP alternative
		case Exiv2::xmpBag: // XMP bag
		case Exiv2::xmpSeq: // XMP sequence
		case Exiv2::langAlt: // XMP language alternative
		case Exiv2::tiffIfd: // TIFF IFD pointer (binary structure)
		case Exiv2::tiffIfd8: // 64-bit TIFF IFD pointer
			return false;
		default:
			// Include all other types: strings, integers, rationals, floats
			return true;
	}
}

static void populate_exif_table(lua_State *L, const Exiv2::ExifData &exif_data) {
	lua_createtable(L, 0, 0);
	for (const auto &it : exif_data) {
		if (!should_include_type(it.typeId())) continue;

		std::string key   = it.key();
		std::string value = it.value().toString();
		lua_pushlstring(L, key.c_str(), key.size());
		lua_pushlstring(L, value.c_str(), value.size());
		lua_settable(L, -3);
	}
}

static Exiv2::ExifData load_image_exif(const std::string &path) {
	try {
		Exiv2::Image::UniquePtr exif_img = Exiv2::ImageFactory::open(path);

		if (!exif_img) return {};

		exif_img->readMetadata();
		return exif_img->exifData();
	} catch (const std::exception &) {
		return {};
	}
}

static int lua_get_meta(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	if (!path) luaL_error(L, "Expected string argument for path");

	populate_exif_table(L, load_image_exif(path));
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

				auto exif_data = load_image_exif(path);

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

extern "C" int luaopen_swi_lib_exiv2_to_lua(lua_State *L) {
	return luaopen_exiv2_to_lua(L);
}
