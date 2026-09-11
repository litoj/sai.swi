# Running the tests and temporary scripts

How module paths resolve, and how to run one-off Lua against the project
modules. Written for the assistant: these are the recurring pitfalls.

## The one rule behind everything

The repo lives at `<swayimg config dir>/sai` (here: `~/.config/swayimg/sai`).
Every module is required under the `sai.` prefix, so a require of
`sai.mode.sort` looks for `sai/mode/sort.lua` **relative to the parent of the
repo**. Whoever sets up `package.path` must provide that parent directory.

## The test suite

```sh
luajit tests/init.lua                     # every module
luajit tests/init.lua sort                # one module (substring match)
luajit tests/init.lua sort.two_lists      # one method (substring match)
luajit tests/sort.lua                     # one module standalone
```

These work from **any cwd**:

- `tests/init.lua` (and every test module) prepends its own directory to
  `package.path`.
- `tests/harness.lua` prepends `H.swayimg_dir` - the repo **parent**,
  computed from the harness source path - so `sai.*` requires always resolve:

  ```lua
  package.path = H.dir .. '/?.lua;' .. H.swayimg_dir .. '/?.lua;' .. package.path
  ```

Do not rely on that setup outside the tests: only the test entry points do it.

## luajit one-liners and temporary scripts

A raw `luajit -e` has none of the above. It only has the default
`./?.lua`:

- the cwd must be the repo **parent** (`~/.config/swayimg`), not the repo
  itself - run from inside the repo and every `sai.*` require fails
- require with the full prefix: `require "sai.bridge.exiv2"`; a bare
  `require "bridge.exiv2"` breaks on its internal `require 'sai.bridge.shell'`
- or set it manually, then any cwd works:

  ```sh
  luajit -e 'package.path = "sai/?.lua;" .. package.path
  local exiv2 = require "sai.bridge.exiv2" ...'
  ```

Scratch data and probe scripts go to `/tmp/opencode`. Never experiment on
files under `~/Pictures` or on committed fixtures - copy them out first.

## CI parity checks

Run from the repo root (`~/.config/swayimg/sai`):

```sh
stylua --check .
lua-language-server --checkmode=global --check=.
cd tests && lua-language-server --checkmode=global --check=.
```

The CI verdict (`.github/workflows/ci.yml`): the report must contain the
`Diagnosis complet` line and no `[Warning]`/`[Error]` lines. Both local
workspaces read `/usr/local/share/swayimg/swayimg.lua` through `.luarc.json`,
the same file CI fetches, so local luals results equal CI's.

The `nvim_dap` module needs a Wayland session: it skips itself in CI's
`tests` job and runs only in the dedicated `nvim_dap` job (headless weston,
swayimg master). On a live desktop session it runs with the full suite.
