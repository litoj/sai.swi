---@module 'sai.bridge.mouse_box'

local utf8 = require 'sai.bridge.utf8'

---Mouse-to-textblock geometry. Every mouse calculation lives here.
---The consumers (the api bind dispatcher, the selector) ask, never compute.
---@class sai.bridge.mouse_box
local M = {
	---Text calibration: one rendered row takes
	---`floor(line_spacing * size) + size * height_factor` px.
	height_factor = 0.75,
	---A character cell takes `size * width_factor` px, rounded to a whole
	---pixel: the renderer advances whole pixels per glyph. Defaults wide (1):
	---a wider hit box confuses less than a narrower one.
	width_factor = 1,
	---The renderer pads every block line with `size * hpad_factor` px on
	---each side, inside the block. Calibrated together with the width.
	hpad_factor = 0,
	---Test seam: fixed metrics instead of the real font lookup.
	---@type false|fun(font:string, size:integer):number?, number?
	_stub_metrics = false,
}

local quad_loc = { TL = 'topleft', TR = 'topright', BL = 'bottomleft', BR = 'bottomright', ST = 'status' }

---@class (exact) sai.bridge.mouse_box.pointer
---@field m {x:integer, y:integer}
---@field ws {width:integer, height:integer}
---@field linepx number
---@field cellpx number
---@field hpad integer
---@field pad integer

---Exact pixel height of a rendered row: the renderer stacks rows on whole pixels,
---so the layout, the row mapping and the page sizing must agree on it.
local function line_px(size, spacing, factor) return math.floor(math.floor(spacing * size) + size * factor) end

local calibrated
---The first mouse query pays the font lookup: nothing before it loads.
local function ensure_calibrated()
	if calibrated then return end
	calibrated = true
	M.calibrate(sai.text.font, sai.text.size)
end

---The pointer plus the px metrics it is judged against.
---@param factor number the height_factor of the text in question
---@return sai.bridge.mouse_box.pointer?
local function pointer(factor)
	ensure_calibrated()
	local m = sai.get_mouse_pos()
	if not m then return end
	local size = sai.text.size
	return {
		m = m,
		ws = sai.get_window_size(),
		linepx = line_px(size, sai.text.line_spacing, factor),
		cellpx = math.floor(size * M.width_factor + 0.5),
		hpad = math.floor(size * M.hpad_factor + 0.5),
		pad = sai.text.padding,
	}
end

---How many rendered rows fit a height budget.
---@param height number available px height
---@param factor number the height_factor of the text in question
---@return integer
function M.rows_in(height, factor)
	local size = sai.text.size
	return math.floor(height / line_px(size, sai.text.line_spacing, factor))
end

---The rendered row count of a block: the source depends on the location.
---Tracked blocks hold processed lines, static ones their template, the status is one string.
---@param mt sai.api.mode_text
---@param loc text_location
---@return integer
local function block_rows(mt, loc)
	if loc == 'status' then
		local s = sai.text.status
		if not s or s == '' then return 0 end
		return select(2, s:gsub('\n', '')) + 1
	end
	---@diagnostic disable-next-line: invisible
	local tr = mt._tracked[loc]
	return tr and #tr.processed or #mt['_' .. loc] ---@diagnostic disable-next-line: invisible
end

---The block width in cells plus its layout: mode_text keeps it current at
---every flush. The status is one string in the api layer.
---@param mt sai.api.mode_text
---@param loc text_location
---@return integer cells
---@return boolean kv the widest line splits into the key and value columns
local function block_cells(mt, loc)
	if loc == 'status' then
		local w = 0
		for l in (sai.text.status or ''):gmatch '[^\n]+' do
			w = math.max(w, utf8.len(l) or #l) -- a bad byte renders as one glyph
		end
		return w, false
	end
	---@diagnostic disable-next-line: invisible
	local m = mt._metrics[loc]
	return m and m.cells or 0, m and m.kv or false
end

---The horizontal span of a block's text.
---@param p sai.bridge.mouse_box.pointer
---@param loc block_position_t
---@param cells integer
---@param kv boolean the widest line splits into the key and value columns: two padded pixmaps, the span covers their gap
---@return number x0 the corner anchors the line's pixmap, whose inner padding offsets the
---  glyphs from the corner - the text reaches only as far as it rendered
---@return number x1
local function x_span(p, loc, cells, kv)
	local w = cells * p.cellpx + (kv and 2 * p.hpad or 0)
	if loc == 'topleft' or loc == 'bottomleft' then
		local x0 = p.pad + p.hpad
		return x0, x0 + w
	end
	local x1 = p.ws.width - p.pad - p.hpad
	return x1 - w, x1
end

---Which candidate section's block contains the pointer; first match wins.
---@param sections string[] candidate sections, quadrant codes
---@return string? section the matching quadrant
---@return integer? row content row: nil over the block's header (its top row)
---@return block_position_t? loc the matched block
function M.block_at(sections)
	local p = pointer(M.height_factor)
	if not p then return end
	local mt = sai.modes[1].text ---@cast mt sai.api.mode_text

	for _, s in ipairs(sections) do
		local loc = quad_loc[s]
		local cells, kv = block_cells(mt, loc)
		local rows = block_rows(mt, loc)
		if cells > 0 and rows > 0 then
			local x0, x1
			if loc == 'status' then
				local w = cells * p.cellpx
				x0, x1 = p.ws.width / 2 - w / 2, p.ws.width / 2 + w / 2
			else
				x0, x1 = x_span(p, loc, cells, kv)
			end
			if p.m.x >= x0 and p.m.x <= x1 then
				if s == 'TL' or s == 'TR' then
					local idx = math.floor((p.m.y - p.pad) / p.linepx) + 1
					if idx >= 1 and idx <= rows then return s, idx ~= 1 and idx - 1 or nil, loc end
				else
					-- a bottom block anchors at the window's bottom edge:
					-- the last line sits on it, the header above the first
					local rel = math.floor((p.ws.height - p.pad - p.m.y) / p.linepx) -- 0 = the bottom-most row
					if rel >= 0 and rel < rows then return s, rel ~= rows - 1 and rows - 1 - rel or nil, loc end
				end
			end
		end
	end
end

---The pager window under the pointer: the location and the absolute line.
---@param pager sai.lib.pager
---@return text_location? loc nil off the rendered area - the block on screen decides, not the pager
---@return integer? line absolute line index
function M.pager_line(pager)
	---@diagnostic disable-next-line: invisible
	if not pager._enabled or #pager._lines == 0 then return end
	local p = pointer(pager.height_factor)
	if not p then return end
	---@diagnostic disable-next-line: invisible
	local loc = pager._location
	local mt = sai.modes[1].text ---@cast mt sai.api.mode_text
	local cells, kv = block_cells(mt, loc)
	local x0, x1
	if loc == 'status' then
		x0, x1 = p.ws.width / 2 - cells * p.cellpx / 2, p.ws.width / 2 + cells * p.cellpx / 2
	else
		x0, x1 = x_span(p, loc, cells, kv)
	end
	if p.m.x < x0 or p.m.x > x1 then return end

	---@diagnostic disable-next-line: invisible
	local from = pager._scroll
	---@diagnostic disable-next-line: invisible
	local visible = pager._last_end - from + 1
	if visible < 1 then return end

	if loc == 'topleft' or loc == 'topright' then
		---@diagnostic disable-next-line: invisible
		local y0 = p.pad + (pager:_header_visible() and p.linepx or 0)
		local rel = math.floor((p.m.y - y0) / p.linepx) + 1
		if rel < 1 or rel > visible then return end -- off the window or over the header
		return loc, from + rel - 1
	end

	-- bottom-anchored (a bottom corner or the status): rel 0 = the last line
	local rel = math.floor((p.ws.height - p.pad - p.m.y) / p.linepx)
	if rel < 0 or rel >= visible then return end -- the padding or the header
	return loc, from + visible - 1 - rel
end

---The line and character under the pointer, for a text pane.
---@param pager sai.lib.pager
---@return integer? line
---@return integer? char utf8 codepoint index, clamped to the line end plus one; a pane with markers maps it past them
function M.char_at(pager)
	local p = pointer(pager.height_factor)
	if not p then return end
	local loc, line = M.pager_line(pager)
	if not line then return end

	-- the block's left edge bounds the column offset
	local mt = sai.modes[1].text ---@cast mt sai.api.mode_text
	local cells, kv = block_cells(mt, loc)
	local x0
	if loc == 'status' then
		x0 = p.ws.width / 2 - cells * p.cellpx / 2
	else
		x0 = x_span(p, loc, cells, kv)
	end

	---@diagnostic disable-next-line: invisible
	local item = pager._lines[line]
	if item == nil then return end
	local rendered = pager:line_fmt(item, line)
	local col = math.floor((p.m.x - x0) / p.cellpx) + 1
	col = math.max(1, math.min(col, utf8.len(rendered) + 1))
	return line, col
end

---Resolve a font the way the app does and measure the text geometry from it:
---everything the lookup needs loads here, so nothing is paid before the first call.
---@param font string face name, as `sai.text.font` holds it
---@param size integer pixel size
---@return number? cell any character's advance in px (a monospace cell)
---@return number? hpad the padding inside a rendered block line, in px
local font_metrics = function(font, size)
	local ffi = require 'ffi'
	-- cdef is process-global: a re-require (the test runner drops modules) must not re-run it
	if not pcall(ffi.typeof, 'FcPattern') then
		ffi.cdef [[
typedef struct FcConfig FcConfig;
typedef struct FcPattern FcPattern;
typedef unsigned char FcChar8;
typedef int FcBool;
typedef int FcResult;
FcConfig* FcInitLoadConfigAndFonts(void);
FcPattern* FcNameParse(const FcChar8* name);
FcBool FcConfigSubstitute(FcConfig* cfg, FcPattern* p, int kind);
void FcDefaultSubstitute(FcPattern* p);
FcPattern* FcFontMatch(FcConfig* cfg, FcPattern* p, FcResult* result);
FcResult FcPatternGetString(FcPattern* p, const char* obj, int id, FcChar8** s);
void FcPatternDestroy(FcPattern* p);
void FcConfigDestroy(FcConfig* c);

typedef struct FT_Size_Metrics_ {
	unsigned short x_ppem, y_ppem;
	long x_scale, y_scale;
	long ascender, descender, height, max_advance;
} FT_Size_Metrics;

typedef struct FT_SizeRec_ {
	void* face;
	void* generic_data;
	void* generic_finalizer;
	FT_Size_Metrics metrics;
} FT_SizeRec;

// the head of the header's FT_FaceRec: the layout up to `size` is ABI-stable
typedef struct FT_FaceRec_ {
	long num_faces, face_index, face_flags, style_flags, num_glyphs;
	const char* family_name;
	const char* style_name;
	int num_fixed_sizes;
	void* available_sizes;
	int num_charmaps;
	void* charmaps;
	void* generic_data;
	void* generic_finalizer;
	long bbox_xMin, bbox_yMin, bbox_xMax, bbox_yMax;
	unsigned short units_per_EM;
	short ascender, descender, height;
	short max_advance_width, max_advance_height;
	short underline_position, underline_thickness;
	void* glyph;
	FT_SizeRec* size;
	void* charmap;
} FT_FaceRec;

typedef struct FT_LibraryRec_ FT_LibraryRec;
typedef int FT_Error;
typedef unsigned int FT_UInt;
typedef unsigned long FT_ULong;
typedef long FT_Long;
typedef long FT_Fixed;
FT_Error FT_Init_FreeType(FT_LibraryRec** alibrary);
FT_Error FT_New_Face(FT_LibraryRec* lib, const char* path, FT_Long face_index, FT_FaceRec** aface);
FT_Error FT_Set_Pixel_Sizes(FT_FaceRec* face, FT_UInt width, FT_UInt height);
FT_UInt FT_Get_Char_Index(FT_FaceRec* face, FT_ULong charcode);
FT_Error FT_Get_Advance(FT_FaceRec* face, FT_UInt gindex, int load_flags, FT_Fixed* padvance);
FT_Error FT_Done_Face(FT_FaceRec* face);
FT_Error FT_Done_FreeType(FT_LibraryRec* lib);
		]]
	end
	local fc, ft = ffi.load 'fontconfig', ffi.load 'freetype'

	-- the app's own font resolution: parse, substitute, match, take the file
	local cfg = fc.FcInitLoadConfigAndFonts()
	if cfg == nil then return end
	local pat = fc.FcNameParse(ffi.cast('const FcChar8*', font))
	if pat == nil then
		fc.FcConfigDestroy(cfg)
		return
	end
	fc.FcConfigSubstitute(cfg, pat, 0) -- 0 = FcMatchPattern, like the app
	fc.FcDefaultSubstitute(pat)
	local res = ffi.new 'FcResult[1]'
	local match = fc.FcFontMatch(cfg, pat, res)
	fc.FcPatternDestroy(pat)
	if match == nil then
		fc.FcConfigDestroy(cfg)
		return
	end
	local file = ffi.new 'FcChar8*[1]'
	local found = fc.FcPatternGetString(match, 'file', 0, file)
	-- the string is owned by the pattern: copy it before the destroy frees it
	local path = found == 0 and ffi.string(file[0]) or nil
	fc.FcPatternDestroy(match)
	fc.FcConfigDestroy(cfg)
	if not path then return end

	local lib = ffi.new 'FT_LibraryRec*[1]'
	if ft.FT_Init_FreeType(lib) ~= 0 then return end
	local face = ffi.new 'FT_FaceRec*[1]'
	if ft.FT_New_Face(lib[0], path, 0, face) ~= 0 then
		ft.FT_Done_FreeType(lib[0])
		return
	end
	ft.FT_Set_Pixel_Sizes(face[0], 0, size)

	-- the app falls back to '?' for a glyph the font lacks
	local idx = ft.FT_Get_Char_Index(face[0], string.byte 'M')
	if idx == 0 then idx = ft.FT_Get_Char_Index(face[0], string.byte '?') end
	local adv = ffi.new 'FT_Fixed[1]'
	local cell = idx ~= 0 and ft.FT_Get_Advance(face[0], idx, 0, adv) == 0 and math.floor(tonumber(adv[0]) / 65536)
		or nil
	-- a block line is a pixmap padded with a third of its base height
	local hpad = math.floor(math.floor(tonumber(face[0].size.metrics.height) / 64) / 3)
	ft.FT_Done_Face(face[0])
	ft.FT_Done_FreeType(lib[0])
	return cell, hpad
end

---Recalibrate the geometry for a font at a size. A failed lookup keeps the
---current values: a wider hit box confuses less than a narrow one.
---@param font string face name, as `sai.text.font` holds it
---@param size integer pixel size
function M.calibrate(font, size)
	local ok, cell, hpad = pcall(M._stub_metrics or font_metrics, font, size)
	if ok and cell and cell > 0 then
		M.width_factor = cell / size
		M.hpad_factor = (hpad or 0) / size
	end
end

return M
