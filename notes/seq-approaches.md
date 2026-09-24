# Key sequences: approach exploration plan

Goal: repeat binds (multiclick counts) turn into a general mappable key
sequence, and the block modifier (`TL+`/`TR+`/`BL+`/`BR+`/`ST+`) works for
keyboard mappings as well. The modifier half is done first as a shared
foundation (`sai.lib.bindmods`); the sequence half is explored along the two
routes below.

## Workflow (agreed)

- We explore all approaches. One git branch per approach:
  - `seq-trampolines` - route A, keep the C-side exact-match dispatch
  - `seq-resolver` - route B, Lua owns the key parsing
- Work on one branch at a time. When done, commit it, switch to the other
  branch, and implement the same feature set there.
- Test-driven: each branch first writes tests for how the mappings must
  resolve in the end, then the implementation. The branches will likely need
  separate test sets: the way of defining key-seq mappings is expected to
  differ between them.

## Definition format (decided)

Multi-key binds use the table form:

```lua
map('1', { a = { PgDown = fn1a }, b = fn1b })
```

- The first argument is the leading key; the table maps each follow-up key
  to an action or a nested table (deeper sequences nest the same way).
- Reasons over the vim-style flat form (`map('ga', fn)`):
  - the flat form needs strict bind parsing, which prevents the plain xkb
    format without `<...>` brackets (a multi-key name would be ambiguous)
  - the table is explicit about where a sequence starts and ends, and it
    maps naturally onto a lookup structure
- Modifier tokens stay string prefixes on the keys, in the canonical
  order established by `sai.lib.bindmods` (count, then section):
  `2+TL+MouseLeft`. On a table bind the tokens of the leading key qualify
  the whole sequence.

## Shared foundation (implemented on the working branch)

Both routes build on the same pieces; they differ only in what registers
with the C api and where the sequence walk is entered from:

- `sai.lib.bindmods` - the modifier registry: each modifier declares how
  to parse its token out of a bind string, how to render it back, and how
  to resolve a live value at dispatch time. `count` (multiclick bursts)
  and `section` (pointer over a text block) are the first two records.
- One dispatcher per raw event name (key or button) in
  `sai.api.mode_base`: qualifier resolution, burst counting, immediate
  fire or deferred fire. Works for any key, not just mouse.
- Canonical bind strings in `_mappings` (registry, backer restore, help
  listing, remapper stacking all keep working on flat string keys).
- The miss path stays: the `on_unassigned` chain and the base fallback.

## Decided: the per-event creator (2026-09-24)

Burst count and continuation are the same mechanism: a bind looks one
step ahead. `2+i` repeats `i`; `g d` follows `d`. Both are the sub-map
walk. The sub-map lands with the sequence work; today the creator
serves the shared foundation only.

One creator (`sai.lib.dispatch`) decides the handler per event name.
`_rawmap` and `_rawunmap` update the event's family set, call the
creator, and register its return value with the host:

- a single plain bind -> the callback itself (`on_key(ev, cb)`),
  nothing wraps it
- any section variant, mouse repeat, or sub-map -> a dispatcher

The dispatcher resolves the live qualifiers (`section`:
BL/BR/TR/TL/ST/none), counts mouse repeats (`2+`/`3+`), and fires the
matched family. A miss runs the unassigned chain (key) or stays silent
(button).

Current scope, deliberately small:

- Repeat binds exist for mouse only. `2+` on a key logs a warning and
  maps as a plain single bind.
- `section` stays live for every event type.
- The event's installed handler is memoized (`_m_handlers`): a re-map
  that rebuilds the same handler skips the re-registration, a change
  swaps the slot and clears the event's burst counters.
- Scroll: since swayimg 5.7 the wheel is one `on_scroll(kmods, h, v)`
  handler, not `on_mouse` buttons. `mode_base` installs that one
  handler and keeps the created scroll handlers in `_m_scroll`, keyed by
  the xkb event. Each axis resolves on its own: an axis claimed by a
  more specific bind zeroes out, the rest of the frame falls through.
  Precedence per axis, most specific first: a
  section-qualified direction (a corner-owned wheel, under the pointer),
  a raw axis bind (`ScrollVertical`/`ScrollHorizontal`, the frame's
  unquantized axis magnitude - it outranks the plain directions, so
  mapping it takes the axis over), a plain direction with an
  unqualified bind in full accumulated steps (quantized, `|delta| >= 1`
  per fire), then a raw `Scroll` bind that receives the unclaimed
  deltas, then the unassigned chain with `Scroll` as the unhandled key. The viewer
  defaults to the raw bind (`pan.by`) and a raw `Ctrl+ScrollVertical`
  zoom, the gallery keeps direction binds (one line per step). A
  single-parameter callback in a custom mode receives the mode (the
  remapper convention), so a scroll axis callback there needs a second
  parameter for the magnitude.

## Open questions

- Pending representation in route A: plain state data, or a transient
  remapper layer per prefix (free which-key display, more churn).
- Typed counts (`3j` with the count as a callback argument) - in scope
  for the sequence work or not; mouse repeats already folded into the
  burst machinery.
- Per-leaf modifier tokens inside a table bind (`{ ['TL+d'] = fn }`):
  allowed, or tokens only on the leading key.

## Status

- Plan written (2026-09-19). The modifier foundation landed on `redo-mappings`
  (`sai.lib.bindmods`, the per-event dispatcher in `mode_base`, tests in
  `tests/bindmods.lua`): tokens parse off any event, one dispatcher serves
  every form of a key, bursts cancel across the event's qualifier paths, and
  unmaps/rebinds retire cleanly (in place, so deferred fires see them).
- Decided (2026-09-24): the per-event creator (`sai.lib.dispatch`) splits
  "direct callback" from "dispatcher"; repeat binds are mouse-only for now
  and `2+` on a key warns and maps as plain. The two sequence branches
  build on this.
- Decided on the way: the burst dimension is a single registry slot (a second
  burst modifier errors at registration); a fire on any path of an event ends
  the pending waits of its other paths (the pointer leaving the block
  mid-burst must not double-fire).
- The two sequence branches start from here.
