# Script library

Small reusable scripts the voice agent can invoke via `run_script` or author
on demand via `author_script`. The runtime loader lives at
[`Ali/executors/local/script_runtime.py`](../../executors/local/script_runtime.py).

## File layout

- `*.sh` — POSIX shell scripts run with `bash`
- `*.applescript` — AppleScript run with `osascript`

Each file starts with a frontmatter block (YAML-ish, embedded in comments).
Shell uses `# ---` delimiters; AppleScript uses `-- ---`.

```
# ---
# name: reveal_in_finder
# runtime: shell
# description: Open Finder revealing the given absolute file path.
# author: seed
# params:
#   - name: path
#     type: abs_path
#     required: true
# ---
```

Required fields: `name` (lowercase snake), `runtime`, `description`, `params`.
Optional: `author` (defaults to `seed`), `created_at`.

## Param types

- `abs_path` — absolute path to an existing file or directory
- `string`   — arbitrary string (no NUL bytes)
- `int`      — integer string

## Arg passing

- **Shell**: params become environment variables prefixed `ALI_ARG_<UPPER_NAME>`.
  Scripts reference them as `"$ALI_ARG_PATH"`. Never interpolate values into
  the script body.
- **AppleScript**: params are passed positionally via `osascript <file> arg1 arg2 …`.
  Scripts read them with `on run argv ... end run`.

## Allowlist (author-time validation only)

There is no per-run confirm. New scripts pass through `validate_body`:

- Shell: only commands from a small allowlist (`open`, `mdfind`, `osascript`,
  standard text tools). Backticks, `$(...)`, heredocs, network tools, `sudo`,
  `rm`, `chmod`, `eval`, etc. are rejected.
- AppleScript: no `do shell script`, `do JavaScript`, `keystroke`, `key code`,
  `open location`, `mount volume`, `eject`. Only `tell application` blocks
  targeting Finder, Mail, Calendar, Contacts, Messages, System Events, Notes,
  or Reminders are permitted.

This is a heuristic safety net, not a sandbox. Anyone with write access to
this directory can ship arbitrary scripts.

## Seed scripts

- [`reveal_in_finder.sh`](reveal_in_finder.sh) — open Finder on a specific file.

Seed scripts cannot be overwritten by Cactus-authored versions.
