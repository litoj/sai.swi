// EXIF data extraction module for Lua using Exiv2.
#include <lua.hpp>

#include <exiv2/exiv2.hpp>

#include <string>

/**
 * Check if an EXIF value should be included based on its type.
 * This filters out complex/binary data like lens correction profiles,
 * keeping only human-readable values (strings, numbers, rationals).
 */
static bool should_include_type(Exiv2::TypeId type) {
	// Explicitly exclude binary and complex types that contain non-human-readable data
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

/**
 * Get EXIF data from an image file.
 * Usage: local exif = require("exiv2_to_lua").get_exif(path)
 * @param path string path to the image file
 * @return table[string]string map of EXIF key-value pairs, or nil on error
 */
static int lua_get_exif(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	if (!path) luaL_error(L, "Expected string argument for path");

	try {
		// Read image metadata using Exiv2
		Exiv2::Image::UniquePtr exif_img = Exiv2::ImageFactory::open(path);

		if (!exif_img) {
			lua_pushnil(L);
			lua_pushstring(L, "Unable to open image file");
			return 2;
		}

		exif_img->readMetadata();
		const Exiv2::ExifData &exif_data = exif_img->exifData();

		lua_createtable(L, 0, 0);

		if (exif_data.empty()) return 1;
		for (const auto &it : exif_data) {
			if (!should_include_type(it.typeId())) continue;

			std::string key   = it.key();
			std::string value = it.value().toString();
			lua_pushlstring(L, key.c_str(), key.size());
			lua_pushlstring(L, value.c_str(), value.size());
			lua_settable(L, -3);
		}

		return 1; // Return the table

	} catch (const std::exception &e) {
		lua_pushnil(L);
		lua_pushstring(L, e.what());
		return 2;
	}
}

/**
 * Module initialization - called when require("exiv2_to_lua") is invoked.
 */
extern "C" LUAMOD_API int luaopen_exiv2_to_lua(lua_State *L) {
	// Create module table
	lua_createtable(L, 0, 1);

	// Add get_exif function
	lua_pushcfunction(L, lua_get_exif);
	lua_setfield(L, -2, "get_exif");

	return 1; // Return the module table
}
