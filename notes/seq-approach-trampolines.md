# Route A: key sequences over trampolines (branch `seq-trampolines`)

The C api keeps its exact-match dispatch. Every event name that any live
bind uses is registered once, with a Lua trampoline. The trampoline runs
the qualifier resolution (bindmods), the burst counting, and the sequence
walk. Single-key binds keep the direct path they have today.

## Data structures

### Bind declarations

The table form maps onto flat sequence keys in `_mappings`:

```lua
map('1', { a = fn, b = { c = fn2 } })
-- stores:
--   _mappings['1 a']      = cfg(fn)
--   _mappings['1 b c']    = cfg(fn2)
```

- The canonical key joins the events with a space, after the modifier
  tokens: `'2+TL+1 a'`. `bindmods.canonical` parses and renders it.
- A flat `map('1 a', fn)` string stays possible (the table is sugar).

### The sequence index (per app mode)

Derived state, maintained by `_setmap`, never stored beside `_mappings`:

```lua
self._seqix = {
	-- one node per event name that starts any bind
	['g'] = {
		terminal = bindcfg,          -- a bind ends here ('g' alone)
		qualified = { TL = bindcfg },-- token-qualified terminals
		branch = {                   -- continuations
			['d'] = { terminal = bindcfg, branch = {...} },
		},
	},
}
```

- A node may hold a terminal and branches at once: that is the
  `g`-alone-and-`g d` conflict, resolved by timeout.
- Removal mutates nodes in place (never rebuild a node object), so a
  deferred fire captured mid-burst sees removals.

### Pending state

```lua
self._pending = {
	node = seqnode,      -- where the walk stands
	tokens = {...},       -- modifier tokens resolved on the first event
	args = {...},        -- their callback payload
	timer = defer_fn id, -- armed after each step
}
```

- Timeout: `multiclick_delay` when the next expected event equals the
  previous one (click coupling), a new `timeoutlen` field otherwise.
- A terminal reached over repeated events fires immediately when no
  longer branch exists - the rule that keeps single clicks latency-free
  today.

## Dispatch flow

`g d` mapped, user presses `g`, then `d`:

1. `g` is registered (it starts a bind) - the trampoline finds
   `_seqix['g']`, arms pending, starts the timeout.
2. `d` arrives at its trampoline: pending descends `branch['d']`,
   terminal without branch - run the action, clear pending.
3. An unlisted key arrives: cancel pending, then re-dispatch that key
   fresh through the same trampoline (a mapped key still runs).
4. The timeout expires first: run the terminal of the pending node if
   one exists (the `g`-alone action), else just cancel.

Qualified sequences (`TL+g d`): tokens resolve on the first event and
ride the pending record; the terminal check re-resolves nothing.

## Interactions

- Layer stack: `_setmap` marks the index dirty (lazy rebuild on the next
  dispatch) and clears pending - a continuation can belong to a popped
  layer. Mode flips re-register per app mode as they do today.
- The pager auto-prefix (`section_key`) keeps working: it produces
  canonical qualified keys before they reach `_setmap`.
- Which-key display, two options:
  - plain state: a `BindPending` event with the alive continuations; the
    corner display of the current top layer renders them.
  - transient remapper layer per (owner, prefix), cached: its
    `help_pager` shows the continuations while armed, `component` keeps
    the mode events quiet. Costs registry churn per prefix press.
- Mouse keeps per-button trampolines (`_m_raw`): `on_mouse` has no
  unassigned hook, so a button must stay registered while any of its
  binds exists.

## Tests (branch-local, written first)

- Resolution: `1 a` fires only in order; a wrong second key re-dispatches
  (a mapped `x` still runs); the leading key alone fires after timeout
  when it has its own terminal.
- Nesting: `1 b c` through the intermediate layer/table.
- Conflict: `g` alone + `g d` - timeout arbitration.
- Table sugar: the flat keys it produces.
- Layering: a sequence bind from an overlay layer restores on disable.

## Benefits / costs

Benefits:
- Single-key binds keep the C fast path; zero added latency there.
- No native-default sweep: the C side sees the same registrations as
  today.
- Incremental migration possible (per mode, per bind kind).

Costs:
- The decline path (modifier inactive, no family matched) must hand-run
  the miss path, so the miss logic exists twice (C-side for unregistered
  events, Lua-side for declined ones) and must stay in sync.
- The prefix/action conflict needs its own arbitration code.
- Two registries to keep consistent: C registrations vs the Lua index.
