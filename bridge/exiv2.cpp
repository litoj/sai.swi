// EXIF data extraction module for Lua using Exiv2.
#include <luajit-2.1/lua.hpp>

#include <exiv2/exiv2.hpp>

#include <string>
#include <thread>
#include <vector>

static bool should_include(const Exiv2::Metadatum &item) {
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

// The loaded facts of one image: the human-readable meta and the actual
// pixel dimensions, decoded from the data (the exif tags can lie about the
// size, the structure cannot).
struct image_info {
	std::vector<std::pair<std::string, std::string>> meta;
	uint32_t width  = 0;
	uint32_t height = 0;
};

static void
populate_exif_table(lua_State *L, const std::vector<std::pair<std::string, std::string>> &meta) {
	lua_createtable(L, 0, meta.size());
	for (const auto &[k, v] : meta) {
		lua_pushlstring(L, k.c_str(), k.size());
		lua_pushlstring(L, v.c_str(), v.size());
		lua_settable(L, -3);
	}
}

static image_info read_image_info(const std::string &path) {
	try {
		Exiv2::Image::UniquePtr exiv2 = Exiv2::ImageFactory::open(path);

		if (!exiv2) return {};

		exiv2->readMetadata();

		image_info info;
		info.width  = exiv2->pixelWidth();
		info.height = exiv2->pixelHeight();
		info.meta.reserve(
		  exiv2->exifData().count() + exiv2->iptcData().count() + exiv2->xmpData().count()
		);

		for (const auto &it : exiv2->exifData())
			if (should_include(it)) info.meta.push_back(std::make_pair(it.key(), it.value().toString()));

		for (const auto &it : exiv2->iptcData())
			if (should_include(it)) info.meta.push_back(std::make_pair(it.key(), it.value().toString()));

		for (const auto &it : exiv2->xmpData())
			if (should_include(it)) info.meta.push_back(std::make_pair(it.key(), it.value().toString()));

		return info;
	} catch (const std::exception &) {
		return {};
	}
}

static void populate_entry(lua_State *L, const image_info &info) {
	populate_exif_table(L, info.meta);
	lua_setfield(L, -2, "meta");

	// only set the dimensions when the decoder knows them: 0
	// means unknown, not "no dimensions"
	lua_pushinteger(L, info.width);
	lua_setfield(L, -2, "width");
	lua_pushinteger(L, info.height);
	lua_setfield(L, -2, "height");
}

static int lua_add_meta(lua_State *L) {
	lua_getfield(L, 1, "path");
	const char *path = lua_tostring(L, -1);
	if (!path) return luaL_error(L, "Expected string argument for path");
	lua_pop(L, 1);

	populate_entry(L, read_image_info(path));
	lua_pop(L, 1);

	return 0;
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
				const char *path = lua_tostring(L, -1);

				lua_pop(L, 2);
				mt.unlock();

				auto info = read_image_info(path);

				mt.lock();
				lua_rawgeti(L, -1, l_idx);

				populate_entry(L, info);

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

extern "C" int luaopen_exiv2(lua_State *L) {
	lua_createtable(L, 0, 2);

	lua_pushcfunction(L, lua_add_meta);
	lua_setfield(L, -2, "add_meta");

	lua_pushcfunction(L, lua_load_all);
	lua_setfield(L, -2, "load_all");

	return 1;
}
