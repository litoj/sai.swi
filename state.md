# Codebase review: `sai.swi`

## Executive summary

The code is dense, clever, and unusually well documented. The tests and the notes are excellent. Most "hacks" are deliberate and commented, which is the main reason the code remains readable.

The main problems are structural:

- The object model is inconsistent. Every file builds inheritance a slightly different way.
- The private-directory (`.lua` files only) edits several host/global functions directly.
- One global function is patched for the whole process.
- Several files reach into the private fields of other files, and suppress the type checker to allow it.
- The same "status is different from blocks" decision is repeated in four places.

The report lists each issue, where it lives, and what structure change removes it.

---

## 1. Hacks on the global environment

### 1.1. Global `tostring` is replaced
- Location: `lib/utils.lua:217`
- Line: `_G.tostring = U.to_pretty_str`

This changes the behavior of `tostring` for the entire process, not only for sai. Any other script or plugin in the same swayimg session gets the pretty printer. It also forces the DAP harness to undo it locally:

- `bridge/debug.lua:440` — `val_str` must flatten multi-line output because the global `tostring` is pretty.

Suggested structure change:

- Do not patch the global. Expose `U.to_pretty_str` and use it at the sai print sites only.
- If the pretty global is required for a good user experience, document it as a deliberate global side effect in the README.

### 1.2. Global shortcut variables
- Location: `api/init.lua:180`, `api/globals.lua`

`_G.sai` is always set. `globals.lua` sets `_G.e/l/t/v/g/s` when loaded. These are opt-in except `sai`. This is a normal plugin convenience. It is not a hack, but it is a global side effect at require time. Document it, or keep it.

### 1.3. Debug harness patches the standard library
- `bridge/debug.lua:762-763` — the harness replaces `debug.traceback` with its own hook function.
- `bridge/debug.lua:774` — `debug.sethook(hook, 'l')` runs a hook at every executed line.

Both affect the whole runtime while a debug session is open. This is the price of a line debugger in LuaJIT. It is acceptable, but note that these are process-global mutations and the harness is a development tool shipped in the same tree. Consider an explicit warning or an opt-in flag.

### 1.4. cjson global configuration
- `bridge/debug.lua:17` — `cjson.encode_empty_table_as_object(true)`.

This is a process-global cjson setting done at module load. Encode it in a comment or move it behind the harness `start()` call.

---

## 2. Direct mutation of the host (swayimg) API

The codebase rules (AGENTS.md) say: never modify the internal state of foreign objects. The code does this in three places, all deliberate and commented:

### 2.1. `viewer.get_image` is wrapped
- `api/viewer.lua:152-163`

The raw swayimg viewer's `get_image` is replaced with a wrapper that prunes `.meta` and caches the image in the exiv2 bridge.

### 2.2. `gallery.get_image` is wrapped
- `api/gallery.lua:94-98`

The raw swayimg gallery's `get_image` is replaced with a wrapper that applies `U.lazymeta`.

### 2.3. Direct host writes under the hood
- `api/init.lua:90` — `swayimg.text.status_timeout = 0` bypasses the sai proxy entirely.
- `api/mode_base.lua:84` and `:104` — `self.super.on_key(...)` and `self.super.on_mouse(...)` write handlers straight onto the host mode objects.

Why these exist:

- swayimg exposes no hook for "image loaded" that carries the exif. The wrap is the only way to intercept.
- The direct writes bypass sai layer bookkeeping on purpose (avoiding event loops).

Suggested structure change:

- Collect all host-API mutation inside one small seam module, for example `bridge/host_poke.lua`.
- Give it a single documented interface per mutation, e.g. `host_poke.wrap_get_image_api(api, decorator)`.
- This centralizes the risk: one file to audit when swayimg changes, and the type checker stops being silenced about the rest.

This also removes most of the `---@diagnostic disable: invisible` lines, which currently hide exactly these cross-boundary pokes.

---

## 3. Workarounds for swayimg limitations

These are documented hacks. They are honest and valuable. They belong to the "limitation workaround" category, not code debt.

### 3.1. "Keep one image" anti-empty-list hack
- `mode/image_filter.lua:28` — `keep_one_image = false, --- Mainline swayimg cannot show text on an empty list -> workaround >:/`
- `_update_live_list` at `:204-227` clears the list and re-adds the current image so an empty list never shows.

### 3.2. Gallery persistent store abused as filter state
- `mode/image_filter.lua:401-403` — the filter mode sets `sai.gallery.pstore_path = '/tmp/sai-filter/'` and forces `pstore = true`.

This uses swayimg's own persistent-store mechanism as a side channel, because the app has no "replace the list without touching gallery state" API.

### 3.3. Shell-command heuristic for list changes
- `api/imagelist.lua:291-302` — a `ShellCmdPost` subscriber looks for `rm` / `mv` in the command text and re-reads the list.

This is the biggest heuristic hack:

- It greps the command string for `rm` and `mv`.
- Any command containing those letters, for example "format", triggers a re-read.
- It misses real changes done without `rm`/`mv`.
- The code says it clearly: `TODO: replace with a proper imagelist change listener`.

The cache is also invalidated by size comparison (`api.size ~= #M._list`) in several places. The two mechanisms overlap.

Suggested structure change:

- Request the swayimg `imagelist` change event (already tracked as an upstream issue).
- Until then, put all cache invalidation behind one function, for example `imagelist._resync()`, and call it from every mutation point (`remove`, `clear`, `add`, `set_order`, the shell heuristic). Today the resync logic is scattered across `M.get`, `M.has`, `marked.get_size`, and `apply_order`.

### 3.4. `_rawunmap` claims app slots to redirect keys
- `api/mode_base.lua:81-86` and `:98-106`

Unmapping a key registers a no-op `on_key` handler so the key falls to the unassigned path instead of the native swayimg default. This is a deliberate "claim the slot" trick. Document it better and move it to one helper.

---

## 4. Code-structure problems

### 4.1. Four different inheritance mechanisms

The codebase uses four mutually inconsistent ways to build an object from a class:

1. Copy all fields: `for k, v in pairs(M) do self[k] = v end`
   - `api/mode_base.lua:139-142`
   - `api/viewer.lua:147-150`
2. Merge defaults: `U.new_object(self, M)`
   - `lib/remapper.lua:69`, `mode/editor.lua:84`, `mode/selector.lua:77`, many more
3. Metatable fallback chain: `setmetatable(M, { __index = M.super })`
   - `lib/pager.lua:80`, `mode/editor.lua:60`, `mode/selector.lua:39`, `mode/help.lua:17`, etc.
4. Explicit class calls: `M.super.new(self)` and `M.super.method(self, ...)`
   - throughout modes

And the `super` field means different things:

- In `api/*` objects, `super` is the raw swayimg API.
- In `mode/*` and `lib/*` objects, `super` is the parent class module table.

Why this hurts:

- A new reader must learn four rules before editing one file.
- Instances carry copies of all methods (`mode_base.new` copies every function). This wastes memory and lets instances drift from the class.
- The bool-return contract of setters is re-defined per layer (`false` = no trigger, `nil` = store, `true` = re-trigger). See `lib/backer.lua:40-48`. Each mode layer re-implements it again with slightly different meaning.

Suggested structure change:

- Introduce one small base class helper, for example `class.lua`:

  ```lua
  local C = {}
  function C.extends(parent) ... end
  function C.new(cls, cfg) ... end
  ```

- One rule: a class has a metatable; `__index` walks the parent class; `new` builds the instance; `super` always means the parent class.
- Keep the raw swayimg API under a different name, for example `_host`, so the word `super` is unambiguous.

This is the single change that reduces the most complexity. It is invasive, but the tests are strong enough to make it safe to do incrementally.

### 4.2. One function does two jobs: map and unmap

- `api/mode_base.lua:129` — `M._rawunmap = M._rawmap`

The same function branches on `action == nil` to decide between mapping and unmapping. The name `_rawunmap` is a lie: it is the same function.

Why it exists:

- The unmap path needs the map path's lookup logic to clean the per-event family tables.

Suggested structure change:

- Split into `_rawmap` and `_rawunmap`, and share only the small lookup helper.
- The shared helper does not need the nil-action branch.

### 4.3. Cross-module private access, hidden from the type checker

The codebase suppresses the `invisible` diagnostic many times (about 30 lines). Each one is a private field read from another module:

- `bridge/mouse_box.lua` reads `sai.api.mode_text._tracked`, `._metrics`, `_lines`, `_scroll` of pagers (8+ lines).
- `mode/key_help.lua` reads `_path`, `_mappings` of other layers (8+ lines).
- `api/init.lua` reads `e._hooks` of the eventloop.

This is the "low coupling" rule failing in several places. The `invisible` suppression is how the code tells itself to ignore the boundary.

Suggested structure change:

- `mode_text` should expose a read API, for example `mode_text:metrics(loc)` and `mode_text:row_count(loc)`, instead of `mouse_box` reaching into `_tracked` and `_metrics`.
- `key_help` should get a read-only view, for example `remapper:effective_binds()` and `remapper:declared_binds()`, instead of iterating `_mappings` of foreign objects.
- `eventloop._hooks` should have `eventloop:has_hooks(event)` instead of direct reads.

### 4.4. The `status` vs. blocks special-case is repeated

The rule "status is one string, blocks are arrays" is repeated verbatim in four places:

- `lib/pager.lua:174-175`, `:192-193`, `:260-261`
- The same idea also appears in `api/init.lua:100`, `api/text.lua`, `bridge/mouse_box.lua:84-86`, and `:96-99`

Three of the four comments read "status is one string, not one line". This is duplicated knowledge. If the app changes how status renders, four files must change together.

Suggested structure change:

- Introduce a tiny value type `text_block` that knows how to hold content (string for status, array for blocks) and present it.
- The pager then branches once -- on construction -- and never checks `_location == 'status'` again.

### 4.5. Utility god-module

`lib/utils.lua` (438 lines) holds unrelated concerns:

- string formatting and table dumping
- stack-trace trimming
- file and directory checks
- exif value parsing
- bind listing and naming
- debounce and lazy proxies

Split candidates:

- `U.tbl_to_str`, `to_pretty_str`, `pretty_trace` → `lib/print.lua`
- `U.format_exif`, `parse_exif_val` → `lib/exif.lua`
- `U.ordered_binds`, `str_bindlist`, `pretty_name` → `lib/bindhelp.lua`
- the rest stays in `utils.lua`

### 4.6. Two parallel metamodel implementations

`api/proxy.lua` and `lib/backer.lua` both implement `__index` / `__newindex`. They differ only in the `super` fallback. Two nearly identical blocks of logic must be kept in sync.

Suggested structure change:

- Make `backer` the one implementation, and give it an optional `super` field. `proxy.lua` then contains only the super-forwarding rule.

### 4.7. Deprecated fake variables that are still bound

- `api/init.lua:24-25` — `_fullscreen` and `_mode` marked "deprecated proxy faking value, not actually used".
- `api/viewer.lua:19-20` — `_position` marked the same way.

But the default bind still toggles a fake value:

- `binds.lua:84` — `map('a', 'f', function() sai.fullscreen = not sai.fullscreen end, 'Toggle fullscreen')`

This bind appears to toggle fullscreen and does nothing real. Reading and writing `sai.fullscreen` only touches the backing field. This is a footgun exposed by a default bind.

Remove the deprecated fields, or wire the bind to a real full-screen mechanism, or show a "not supported" notify.

### 4.8. `on_window_resize` re-implements init vs. resize

- `api/init.lua:182-233`

The same callback distinguishes three states: initialization, deduplication of the initial resize, and real resize. Comment at `:187` admits: `TODO: find a way to distinguish focus events from resizing`.

Suggested structure change:

- Move this into a small state machine: `init → ready`, with the dedup flag inside it.
- Keep the easter egg out of this code path (see section 6).

### 4.9. `debug.lua` is a full protocol implementation in one file

885 lines is large but coherent. The DAP handlers table is clean. No change needed in spirit; consider splitting the message frame parser (`parse_frames`, `send_msg`) from the handlers for testability.

### 4.10. Test globals juggling

- `tests/harness.lua:705-714`, `tests/api.lua`, `tests/viewer.lua`, `tests/mode_text.lua`, `tests/reconfigurer.lua`

Every test module saves and restores `_G.swayimg` / `_G.sai` by hand. This is the same global-state coupling that section 1.2 describes. It works, but it is duplicated boilerplate. A harness helper, for example `H.with_env(env, fn)` -- it exists only inside `recording_stack` -- should be promoted to a shared exported helper.

---

## 5. Clean-code violations in detail

### 5.1. Many

### 5.1. Redundant comments

The codebase has an excellent comment-style spec (`notes/comment-style.md`). Most comments follow it. A few do not:

- "status is one string, not one line" repeated three times in `pager.lua` (174, 192, 260). The name or the code does not need it after the first use.
- `mode/editor.lua:315-316` and `:320-321` — the same comment "the new line may be shorter: re-clamp the column into it" appears twice for `move_up` and `move_down`. Extract one shared clamp.
- `api/proxy.lua:58-60` — two consecutive comments say almost the same thing about the same one-liner.

### 5.2. Minor cosmetic bug in a message

- `lib/keybind_processor.lua:83` — the duplicate-warning format string ends with a stray `)`. Every duplicate-mapping log line shows a trailing `)`.

### 5.3. Duplicated logic that already has a note

The test-structure note (`notes/test-structure.md`, pending section) already says:

- `api/viewer.lua` keep_* resubscription duplicates the arm/replace shape of the defer chain. A shared replace-not-stack primitive could serve both.

This is a confirmed duplication. Either implement the shared primitive or close the note.

### 5.4. `image_filter` error-value closure

- `mode/image_filter.lua:51-52, 62` — `local val` captured in a closure, then exposed through `self._err_val()`.

This is an awkward way to carry "the last value that failed". It works, but it is a hidden mutable channel between the filter engine and the error report. Consider returning the failing value from the match loop instead of stashing it on `self`.

### 5.5. `editor` letter-hijack

- `mode/editor.lua:97-107` — the editor pre-maps every `Shift+<letter>` key to route through `on_unassigned` and then `X.process_next_input`.

This is clever but indirect: the editor declares 26 invisible binds so that input flows through the key processor. Every Shift-letter press pays a full bind-resolution round-trip. Consider documenting this in one place, or handle text input in the unassigned chain directly instead of pre-registering keys.

### 5.6. `os.rename(x, x)` used as an existence check

- `bridge/shell.lua:161`, `:188`
- `bridge/utf8.lua:63`

Renaming a file onto itself succeeds only if the file exists. This is a valid idiom, but it is non-obvious and it performs a real syscall. The `utf8.lua:63` and `shell.lua:188` calls use it to decide whether to download/compile. It will also return `nil, err` on some rare filesystems. A small `U.file_exists` helper would make the intent obvious.

### 5.7. `ffi.typeof` guard for re-require safety

- `bridge/deferred_heap.lua:12`
- `bridge/mouse_box.lua:242`

`ffi.cdef` is process-global, so a re-require (the test runner drops the module cache) must not declare a struct twice. The guard `pcall(ffi.typeof, ...)` is a test-driven workaround. It is correct and commented. Consider one shared `bridge/cdef.lua` that owns each cdef block with its guard, because `socket.lua` and `debug.lua` already centralize theirs there. Then no module needs its own guard.

### 5.8. The `e.ignore_opts` global flag

- `api/eventloop.lua:19`
- used in `lib/backer.lua:27-37`, `lib/reconfigurer.lua`, `api/init.lua:78-111`

A global mutable flag must be saved and restored at every call site. `backer` restores it inside a `pcall`, which is correct. The pattern is error-prone if a new call site forgets the restore.

Suggested structure change:

- Move the flag argument into the trigger call: `e.trigger { ..., silent = true }`.
- This removes the global and the save/restore dance entirely.

---

## 6. Minor hacks and legacy

### 6.1. Easter egg
- `api/init.lua:211-216` — on the date 10/03, the code shells out to `date +%d%m` and prints a "naughty" message. Fun, but it is dead weight in the hot init path and confuses readers. Move it to `snippets.lua` or remove it.

### 6.2. `snippets.update` hot-reload
- `snippets.lua:9-24` — recompiles `.so` files and copies the new symbols into the old `package.loaded` table in place. This is a live-reload hack. It is fine for a development workflow, but document that stale objects survive (old closures keep old symbols).

### 6.3. `defer_fn` argument-order compatibility
- `api/init.lua:128-133` — accepts `(cb, ms)` and `(ms, cb)`. The number-first form exists for backward compatibility. Keep it, but note it in one place.

### 6.4. Manual `rawset` caching of pid/cmdline
- `api/init.lua:158-175` — reads `/proc/<pid>/cmdline` and caches it with `rawset`. Fine; the cmdline can change but the cache is documented as read-only.

---

## 7. Recommended structural changes (in priority order)

These changes directly remove most of the hacks above.

1. **One class mechanism** (section 4.1). Introduces the largest cleanup: fewer surprises, no method copying, unambiguous `super`.
   - Removes the four inheritance styles.
   - Removes `U.new_object` from most call sites.
   - Makes the bool-return setter contract a documented part of the base class.

2. **One seam for host-API mutation** (section 2).
   - Gives the three host pokes a single home.
   - Removes the need for most `invisible` suppressions.

3. **Split `_rawmap` / `_rawunmap`** (section 4.2).
   - Small, safe, standalone.

4. **Expose real reader methods instead of `invisible` access** (section 4.3).
   - `mode_text:metrics()`, `remapper:effective_binds()`, `eventloop:has_hooks()`.

5. **Abstraction for the status-vs-block rule** (section 4.4).
   - `text_block` value type; one branch instead of four.

6. **Don't patch the global `tostring`** (section 1.1).
   - Use the pretty printer only at sai sites.

7. **Remove the deprecated fake vars and their binds** (section 4.7).

8. **One `imagelist` resync point** (section 3.3).
   - Centralize cache invalidation; keep the heuristic clearly marked and replace it when the upstream listener lands.

9. **`silent` option on trigger instead of `e.ignore_opts`** (section 5.8).

10. **Split `utils.lua`** (section 4.5) into `print`, `exif`, and `bindhelp`.

## 8. Non-issues worth keeping

- The layer/override system in `lib/reconfigurer.lua` and `lib/registry.lua` is complex but well-factored and heavily tested. Keep it.
- The DAP harness globals (hook, traceback) are acceptable in a dev-only tool.
- The `once`-style self-removal patterns in the eventloop are safe because `trigger` collects hooks before calling them (`api/eventloop.lua:245-255`). Good design.
- Tests demonstrate the intended usage and are an excellent documentation by example.

---

## Final notes

The report follows the codebase's own review rules (consistency, coverage, readability, documentation). The comments are mostly correct and explain the "why". The main target of a cleanup is not the comments -- it is the object model and the host-poke seams.

If you want, I can:
- Draft the `class.lua` base and migrate one class (for example `selector -> pager -> remapper`) as a first, fully tested step.
- Or start with the two smallest wins: splitting `_rawmap`/`_rawunmap`, and the trigger `silent` option.

Your call on where to start.
