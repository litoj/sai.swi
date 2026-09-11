# Test structure: one file per source

This note records the test layout rule and the follow-ups it surfaced. It is
a self-instruction for the assistant. Follow it before you add any test.

## The 1:1 rule

One test file covers exactly one source file. The name matches the source
basename: `api/eventloop.lua` is covered by `tests/eventloop.lua`,
`mode/key_help.lua` by `tests/key_help.lua`.

A test that needs a second module as a fixture (key_help tests enabling
var_help) still lives in the subject's file. Shared doubles stay in
`tests/harness.lua`. No test file requires another test file.

## Done

- `tests/api.lua` held notify, cmdline, heap scheduling and viewer scale.
  Split into `tests/api.lua`, `tests/deferred_heap.lua`, `tests/viewer.lua`.
- `tests/proxy.lua` held a `mode_base` regression. Moved to
  `tests/mode_base.lua`.
- `tests/help.lua` held key_help, var_help and binds coverage. Split into
  `tests/help.lua`, `tests/key_help.lua`, `tests/var_help.lua`,
  `tests/binds.lua`.
- Empty placeholders reserve the name and list what to pin:
  `tests/gallery.lua`, `tests/text.lua`, `tests/socket.lua`,
  `tests/keybind_processor.lua`, `tests/reconfigurer_evloop.lua`.

## Done later

- `tests/socket.lua`, `tests/keybind_processor.lua`,
  `tests/reconfigurer_evloop.lua`: real tests now (framing, canonicalization,
  enable cycle). `tests/gallery.lua` and `tests/text.lua` stay empty stubs:
  their logic is seeded proxies pinned through `tests/mode_text.lua`.
- xkb `MKB` assert message reads `XKB`; `bridge/shell.expand(a,type)` args
  renamed `(lead, ph)` (no more shadowed builtin).
- Open API question (not renamed): `ipc.server/client` factories vs the
  `listen/connect` verb pair - public surface, needs litoj's call.

## Done round 3

- Scheduling moved: `api/init.lua` keeps only the `defer_fn` surface (with
  its number-first compat swap); `bridge/deferred_heap.lua` owns push,
  single-slot arm with a generation guard, pop, callback error isolation
  and re-arm - the same boundary as `M.exec` pointing at the shell bridge.
  `tests/deferred_heap.lua` pins the gen guard, error isolation, due order
  and the 1ms default directly against the heap.
- Parked tests found their 1:1 homes: the sub-mode tab/group tests moved
  onto their subjects (`tabs_group_sub_modes` in `tests/key_help.lua`,
  `components_grow_no_varset_groups` in `tests/var_help.lua`,
  `corner_lists_components` in `tests/image_filter.lua`).
- `tests/debug.lua`: stepIn depth, the pause-while-stopped contract
  (answered, cancelled by the next continue - mid-run pause needs the io
  signal the plain-luajit double cannot deliver), unknown-command generic
  success, terminateDebuggee process exit.
- `nvim_dap.lua`: `resolve`/`sockets` take an injected `{glob, fs_stat}`
  probe (production defaults unchanged), `runtime_dir` resolved once from
  `vim.env` or `os.getenv`. Plain-luajit unit tests cover pipe/pid/counts.
- The `dap_session` e2e gate is verified live: with any fullscreen window
  focused, the test swayimg never renders and the disconnect ack never
  arrives - environment, exactly as tests/nvim_dap.lua's header states.

## Pending source considerations (not tests)

- `api/viewer.lua` keep_* resubscription duplicates the arm/replace shape
  of the defer chain; a shared replace-not-stack primitive could serve both.
