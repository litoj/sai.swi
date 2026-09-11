# Route B: the resolver owns the keys (branch `seq-resolver`)

No real action is ever registered with `on_key`. Every key with no
native bind arrives through `on_unassigned_key` at one resolver in
`sai.api.mode_base`. The resolver runs the qualifier resolution
(bindmods), the sequence walk, and the burst counting; a miss runs the
existing `on_unassigned` chain and the base fallback.

Mouse stays as in route A: `on_mouse` has no unassigned hook, so each
used button keeps its trampoline. The "own everything" property holds for
keyboard only.

## Data structures

Identical to route A (sequence index, pending state, canonical flat
keys, table sugar): the difference is the entry point, not the storage.
`_seqix` and `_m_fam` merge into one index - nothing registers with C
per key, so the split between "direct binds" and "dispatch binds"
disappears.

## The native-default sweep

Today a key is "unmapped" by registering the fallback with `on_key`
(`mode_base._rawmap`), so the C unassigned hook fires only for keys
nobody ever registered. Route B removes the registrations, which means
every swayimg built-in default must be explicitly dropped up front, or
it fires in C without Lua seeing it:

- `binds.default` grows from the keypad list to the complete set of
  swayimg defaults (arrows, Escape, +/-, F-keys, ... - the list from
  swayimg's appmode.cpp).
- The sweep is a standing coupling to upstream: a new native default in
  a swayimg update stays silently active until noticed and added.
- The `_rawunmap` of a key keeps working as a no-op-with-fallback, since
  nothing was ever registered.

## Dispatch flow

`g d` mapped, user presses `g`, then `d`:

1. `g` has no registration - C calls the resolver through
   `on_unassigned_key`.
2. The resolver walks the index, arms pending, swallows the key.
3. `d` likewise; terminal without branch - run, clear.
4. A miss (no sequence, no qualifier match) runs the `on_unassigned`
   chain exactly as an unmapped key does today.

Semantic inversion: "unassigned" today means "no layer claimed this
key"; here it means "the resolver declined this key" - which includes
mapped-but-inactive binds (a section bind with the pointer off its
block, a timed-out sequence). The chain consumers (the editor's text
input, debug layers) see the same contract: keys the mapping layer did
not use.

## Interactions

- Layer stack: unchanged. Layers write through `_setmap`; the resolver
  reads the live index each keypress, so a mode flip needs no
  re-registration at all.
- The pager auto-prefix and remapper stacking see canonical strings,
  same as route A.
- Tests drive everything through `raw_binds['viewer:unassigned']` - one
  path, no dual assertions between direct and dispatched keys.

## Tests (branch-local, written first)

- Same resolution set as route A (order, wrong key re-feed, timeout
  terminal, nesting, conflict, table sugar, layering).
- The sweep: every swayimg default lands in the resolver (a recorded
  raw_swayimg double asserts the fallback chain got the key).
- Decline cases: a section bind with the pointer off its block reaches
  the chain and the base fallback, not a silent drop.

## Benefits / costs

Benefits:
- One uniform decision path: map hit, sequence walk, decline, fallback
  - all in one function, one ordering.
- No trampoline decline routing (route A's duplicated miss logic).
- No registration churn on mode flips; easiest mental model.

Costs:
- The complete native-default sweep, with the upstream coupling above.
- Every keystroke pays one Lua hop.
- The asymmetry stands: mouse keeps the trampoline path anyway.
