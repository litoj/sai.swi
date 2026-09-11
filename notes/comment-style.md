# Comment style for this codebase

This note defines the rules for writing comments and documentation. It is a
self-instruction for the assistant. Follow it before you add any comment to the
code.

## The purpose of a comment

A comment clarifies what is not obvious. It does not restate what the name,
the type, or the code already say.

The name, the type, and the code are the primary documentation. Add a comment
only when they do not tell the full story.

## Layout

Put the description directly next to the item it describes. Do not collect all
descriptions into one large block in the method or class description.

Use `types.lua` as the reference example. In that file:

- A `@param` line holds its description on the same line.
- A `@field` line holds its description on the same line.
- A `@return` line holds its description on the same line.
- A `@class` line carries at most one short line of context.

Good form (`types.lua`):

```lua
---@field enable? boolean Fix colors using white balance from camera
```

Bad form (everything above the item):

```lua
---Fix colors using white balance from camera.
---This flag is set by the camera.
---@field enable? boolean
```

## Structure of a doc block

A doc block has exactly this shape, in this order:

1. The brief: what the item is or does, in at most two lines.
2. The typedoc lines (`@param`, `@return`, `@field`, `@class`, `@type`,
   `@alias`, `@see`, `@generic`, `@overload`), each with its own description.

Rules:

- The brief never carries text that belongs on a typedoc line. What a parameter
  is goes on its `@param`, what a function returns goes on its `@return`, what
  a field holds goes on its `@field`.
- `@param`/`@return`/`@field` lines always describe the item when the type
  alone does not say it. A return value described in the brief instead of on
  `@return` is a violation.
- A brief of more than two lines is a violation. A long explanation must be
  structured into points or simple sentences on the typedoc lines or be
  shortened.
- One sentence, or two short ones, is best for a brief.

The self-check for the previous paragraph, in concrete terms:

- `@return boolean? closing verdict` - the description is on the `@return`
  line, not in the brief.
- `@param pager sai.lib.pager` with the pager's role explained only in the
  brief - violation.

## When a comment must exist

Write a comment only when one of these is true:

- The behavior is a trap. The code looks correct, but it is not. State the trap.
- The behavior has a hidden cause. The call chain or the metatable decides the
  result. State the cause.
- The behavior has a contract. The caller must know it. State the contract.
- The code is hard to grasp. The comment explains the mechanism.
- A generic improves the typehint for object traversal. Keep the `@generic`
  and the typed `@param self`.

The useful part of a comment is the "why". State the why, not the what.

## When a comment must NOT exist

Do not write a comment when one of these is true:

- The function name states the behavior. A comment that rephrases the name is
  word-for-word redundant. Example: `get_current_line_info` needs no
  "returns the current line".
- The type states the meaning. `@param title string` needs no `title title`.
- The annotation is a plain restatement. `@return string` over a function whose
  name ends in `_name` needs no extra wording.
- The parameter is a backer set/get method. These methods are never called
  directly. Lua reaches them only through the metatable. The field they back
  already carries the description. Example: `set_enabled`, `set_location`.
- The member starts with `_`. The luarc (`protectedName: ["^_[^_]"]`)
  auto-protects every underscore-prefixed member, so an explicit `@protected`
  on it is redundant. Write no `@protected` for a `_`-prefixed name at all.
- The annotation brings no value. It only clutters the file.
- The type annotation is inherited. An override must not repeat the lines that
  its parent class already declares. Example: a `parse_input` override must not
  re-declare the parent annotation.
- The line is a metatable or proxy shim. These lines help the type checker
  across objects. They need no prose.

## The decision procedure

Ask these questions in order. Stop at the first "no".

1. Does the name say it? If yes, write nothing.
2. Does the type say it? If yes, write nothing.
3. Does the code say it? If yes, write nothing.
4. Does the comment add the "why" or a trap? If no, write nothing.
5. Does the generic help the type checker follow the object? If yes, keep the
   generic and the typed `self`. Write nothing else.

## Rules for the text itself

- Keep the comment short. One sentence is best.
- A comment longer than two lines: structure it into points or simple sentences.
- Use the present tense. Use the active voice.
- Use the same words as the code does. Do not invent synonyms.
- Do not explain a comment with another comment.

## Unacceptable, with examples

What does not pass review:

- A brief of three or more lines. Shorten it or move the text onto the typedoc
  lines.
- A return value described only in the brief. It belongs on `@return`.
- A parameter described only in the brief. It belongs on `@param`.
- A field described above its `@field` line. It belongs on the `@field` line.
- A run-on paragraph over 200 chars. Split it into points.

## Self-check before you finish

Review the diff before you finish:

- Every new comment answers a "why" or states a trap.
- No comment restates a name.
- No comment restates a type.
- No backer set/get method holds a param description.
- No override repeats an inherited annotation.
- No method where the typehint is obvious carries an empty `@param` with a
  meaningless description.
- No `_`-prefixed member carries an explicit `@protected`.

If a line fails the check, remove the comment, not the code.
