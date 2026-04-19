"""
Layer 4A — Local Executor: Script runtime.

A small library of reusable scripts (shell + AppleScript) that the agent can
either reuse (`run_script`) or author on demand (`author_script`). Scripts
live as plain text files under `Ali/scripts/library/` with YAML-ish
frontmatter embedded in comments.

Safety model: author-time allowlist only. Newly authored scripts go through
`validate_body` which rejects dangerous primitives. There is NO per-run
confirmation gate — the planner can invoke passing scripts directly.

Arg passing:
  - shell     -> each declared param becomes env var ALI_ARG_<UPPER_NAME>.
                 Body reads `"$ALI_ARG_PATH"` (no string interpolation).
  - applescript -> positional argv via `on run argv ... end run` in the
                   script; runner passes args in the order params are
                   declared.

Scripts are discovered at startup via `load_catalog()` and re-scanned after
each successful `author_script`.
"""

from __future__ import annotations

import asyncio
import hashlib
import re
import shutil
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

SCRIPT_LIBRARY_DIR = Path(__file__).resolve().parents[2] / "scripts" / "library"

# ─── Types ────────────────────────────────────────────────────────────────────


class ScriptValidationError(ValueError):
    """Raised when a script body or frontmatter fails validation."""


class ScriptExecutionError(RuntimeError):
    """Raised when a script invocation fails in a non-recoverable way."""


VALID_PARAM_TYPES = {"abs_path", "string", "int"}


@dataclass(frozen=True)
class ScriptParam:
    name: str
    type: str
    required: bool = True
    default: str | None = None


@dataclass(frozen=True)
class ScriptSpec:
    name: str
    runtime: str  # "shell" | "applescript"
    description: str
    params: tuple[ScriptParam, ...]
    author: str  # "seed" | "cactus"
    source_path: Path
    body: str
    sha256: str

    def summary(self) -> dict:
        return {
            "name": self.name,
            "runtime": self.runtime,
            "description": self.description[:120],
            "params": [
                {"name": p.name, "type": p.type, "required": p.required}
                for p in self.params
            ],
        }


@dataclass(frozen=True)
class ScriptRunResult:
    name: str
    returncode: int
    stdout: str
    stderr: str
    duration_ms: int

    def ok(self) -> bool:
        return self.returncode == 0


# ─── Validators ───────────────────────────────────────────────────────────────


_SHELL_ALLOWLIST = frozenset(
    {
        "open", "mdfind", "osascript", "ls", "cat", "grep", "rg", "find",
        "head", "tail", "wc", "echo", "printf", "which", "test", "sed",
        "awk", "date", "basename", "dirname", "realpath", "stat",
        "pbcopy", "pbpaste", "set", "true", "false", "sleep", "[",
    }
)

_SHELL_DENYLIST_TOKENS = (
    "rm", "sudo", "curl", "wget", "scp", "ssh", "ftp", "nc", "launchctl",
    "defaults", "chmod", "chown", "kill", "killall", "eval", "exec",
    "source", "trap", "dd",
)

_SHELL_DENYLIST_SUBSTRINGS = (
    "`", "$(", "<(", ">(", "&>", "2>&1 >", "| sh", "| bash", "| zsh",
)

_APPLESCRIPT_DENYLIST_SUBSTRINGS = (
    "do shell script",
    "do javascript",
    "do script",
    "open location",
    "mount volume",
    "eject",
    "keystroke",
    "key code",
)

_APPLESCRIPT_ALLOWED_APPS = {
    "Finder", "Mail", "Calendar", "Contacts", "Messages",
    "System Events", "Notes", "Reminders",
}

_MAX_BODY_LEN = 4096


def validate_body(runtime: str, body: str) -> None:
    """Raise ScriptValidationError if the body is unsafe to persist or run."""
    if not isinstance(body, str) or not body.strip():
        raise ScriptValidationError("empty script body")
    if len(body) > _MAX_BODY_LEN:
        raise ScriptValidationError(f"script body exceeds {_MAX_BODY_LEN} bytes")

    if runtime == "shell":
        _validate_shell_body(body)
    elif runtime == "applescript":
        _validate_applescript_body(body)
    else:
        raise ScriptValidationError(f"unsupported runtime: {runtime!r}")


def _validate_shell_body(body: str) -> None:
    for bad in _SHELL_DENYLIST_SUBSTRINGS:
        if bad in body:
            raise ScriptValidationError(f"shell body contains disallowed substring: {bad!r}")

    for raw_line in body.splitlines():
        line = _strip_shell_comment(raw_line).strip()
        if not line:
            continue
        # Shebang / option lines pass through.
        if line.startswith("#!"):
            continue
        if line.startswith("set ") and all(
            part.startswith("-") or part in {"-e", "-u", "-o", "pipefail"}
            for part in line.split()[1:]
            if part
        ):
            continue

        for segment in _split_shell_logical(line):
            head = _first_shell_token(segment)
            if head is None:
                continue
            if head in _SHELL_DENYLIST_TOKENS:
                raise ScriptValidationError(
                    f"shell token {head!r} is not allowed"
                )
            if head in _SHELL_ALLOWLIST:
                continue
            # Allow simple variable assignments like FOO=bar when at line head.
            if "=" in head and not head.startswith("="):
                continue
            raise ScriptValidationError(
                f"shell token {head!r} is not on the allowlist"
            )

    # Only allow redirects to /dev/null.
    for match in re.finditer(r">{1,2}\s*(\S+)", body):
        target = match.group(1)
        if target not in {"/dev/null", "&1", "&2"}:
            raise ScriptValidationError(
                f"shell redirect target {target!r} is not allowed"
            )


def _validate_applescript_body(body: str) -> None:
    lowered = body.lower()
    for bad in _APPLESCRIPT_DENYLIST_SUBSTRINGS:
        if bad in lowered:
            raise ScriptValidationError(
                f"applescript body contains disallowed construct: {bad!r}"
            )
    for match in re.finditer(r'tell\s+application\s+"([^"]+)"', body, re.IGNORECASE):
        app = match.group(1)
        if app not in _APPLESCRIPT_ALLOWED_APPS:
            raise ScriptValidationError(
                f"applescript tells application {app!r} which is not allowed"
            )


def _strip_shell_comment(line: str) -> str:
    # Very simple: drop anything after an unquoted '#'. Good enough for our
    # small allowlisted surface — quoted '#' in arguments is uncommon in the
    # seed scripts and authoring prompts.
    in_single = False
    in_double = False
    out_chars: list[str] = []
    for ch in line:
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            break
        out_chars.append(ch)
    return "".join(out_chars)


def _split_shell_logical(line: str) -> Iterable[str]:
    # Split on ; && || | while respecting quotes. Keep implementation simple.
    buf: list[str] = []
    in_single = False
    in_double = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "'" and not in_double:
            in_single = not in_single
            buf.append(ch)
            i += 1
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            buf.append(ch)
            i += 1
            continue
        if not in_single and not in_double:
            if line.startswith("&&", i) or line.startswith("||", i):
                yield "".join(buf).strip()
                buf = []
                i += 2
                continue
            if ch in (";", "|"):
                yield "".join(buf).strip()
                buf = []
                i += 1
                continue
        buf.append(ch)
        i += 1
    if buf:
        yield "".join(buf).strip()


def _first_shell_token(segment: str) -> str | None:
    stripped = segment.strip()
    if not stripped:
        return None
    # Strip simple leading env-var assignments (FOO=bar BAR=baz cmd ...).
    parts = stripped.split()
    while parts and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", parts[0]):
        parts.pop(0)
    if not parts:
        return None
    return parts[0]


# ─── Frontmatter parsing ──────────────────────────────────────────────────────


_FRONTMATTER_DELIMS = {
    "shell": ("# ---", "# ---"),
    "applescript": ("-- ---", "-- ---"),
}

_COMMENT_PREFIXES = {"shell": "# ", "applescript": "-- "}


def _runtime_from_path(path: Path) -> str | None:
    if path.suffix == ".sh":
        return "shell"
    if path.suffix == ".applescript":
        return "applescript"
    return None


def parse_frontmatter(text: str, runtime: str) -> dict:
    """
    Extract the frontmatter block from a script body. Returns a dict with
    keys 'name', 'runtime', 'description', 'params', 'author'.
    """
    delim_open, _ = _FRONTMATTER_DELIMS[runtime]
    prefix = _COMMENT_PREFIXES[runtime]

    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == delim_open.strip():
            start = i
            break
    if start is None:
        raise ScriptValidationError("missing frontmatter open delimiter")

    end = None
    for j in range(start + 1, len(lines)):
        if lines[j].strip() == delim_open.strip():
            end = j
            break
    if end is None:
        raise ScriptValidationError("missing frontmatter close delimiter")

    body_lines = [
        line[len(prefix):] if line.startswith(prefix) else line.lstrip("-# ").rstrip()
        for line in lines[start + 1 : end]
    ]

    return _parse_simple_yaml(body_lines)


def _parse_simple_yaml(lines: list[str]) -> dict:
    data: dict = {}
    current_list_key: str | None = None
    current_item: dict | None = None

    for raw in lines:
        if not raw.strip():
            continue
        stripped = raw.rstrip()
        indent = len(raw) - len(raw.lstrip(" "))

        if indent == 0:
            key, _, value = stripped.partition(":")
            key = key.strip()
            value = value.strip()
            if not key:
                continue
            if not value:
                data[key] = []
                current_list_key = key
                current_item = None
            else:
                data[key] = _coerce_scalar(value)
                current_list_key = None
                current_item = None
            continue

        if current_list_key is None:
            continue

        content = stripped.lstrip()
        if content.startswith("- "):
            current_item = {}
            data[current_list_key].append(current_item)
            content = content[2:].strip()
            if content:
                k, _, v = content.partition(":")
                if k and v:
                    current_item[k.strip()] = _coerce_scalar(v.strip())
        elif current_item is not None and ":" in content:
            k, _, v = content.partition(":")
            current_item[k.strip()] = _coerce_scalar(v.strip())

    return data


def _coerce_scalar(value: str):
    lowered = value.lower()
    if lowered in {"true", "yes"}:
        return True
    if lowered in {"false", "no"}:
        return False
    if value.isdigit():
        return int(value)
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        return value[1:-1]
    return value


# ─── Catalog loading ──────────────────────────────────────────────────────────


def load_catalog(library_dir: Path | None = None) -> dict[str, ScriptSpec]:
    """Scan the script library directory and return `name -> ScriptSpec`."""
    root = library_dir or SCRIPT_LIBRARY_DIR
    if not root.exists():
        return {}
    catalog: dict[str, ScriptSpec] = {}
    for path in sorted(root.iterdir()):
        if not path.is_file():
            continue
        runtime = _runtime_from_path(path)
        if runtime is None:
            continue
        try:
            spec = _spec_from_path(path, runtime)
        except ScriptValidationError as exc:
            print(f"[script-runtime] skip {path.name}: {exc}")
            continue
        if spec.name in catalog:
            print(
                f"[script-runtime] duplicate script name {spec.name!r}; "
                f"keeping {catalog[spec.name].source_path.name}, "
                f"ignoring {path.name}"
            )
            continue
        catalog[spec.name] = spec
    return catalog


def _spec_from_path(path: Path, runtime: str) -> ScriptSpec:
    body = path.read_text(encoding="utf-8")
    meta = parse_frontmatter(body, runtime)
    name = str(meta.get("name", "")).strip()
    if not name or not re.fullmatch(r"[a-z][a-z0-9_]{1,63}", name):
        raise ScriptValidationError(f"invalid or missing script name in {path.name}")
    if meta.get("runtime") and str(meta["runtime"]).strip() != runtime:
        raise ScriptValidationError(
            f"runtime mismatch in {path.name}: frontmatter says "
            f"{meta['runtime']!r} but file extension implies {runtime!r}"
        )
    description = str(meta.get("description", "")).strip()
    author = str(meta.get("author", "seed")).strip() or "seed"
    params = _parse_params(meta.get("params", []) or [])
    return ScriptSpec(
        name=name,
        runtime=runtime,
        description=description,
        params=params,
        author=author,
        source_path=path,
        body=body,
        sha256=hashlib.sha256(body.encode("utf-8")).hexdigest(),
    )


def _parse_params(raw: list) -> tuple[ScriptParam, ...]:
    out: list[ScriptParam] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name", "")).strip()
        if not name or not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", name):
            raise ScriptValidationError(f"invalid param name: {entry!r}")
        ptype = str(entry.get("type", "string")).strip() or "string"
        if ptype not in VALID_PARAM_TYPES:
            raise ScriptValidationError(f"unsupported param type: {ptype!r}")
        required = bool(entry.get("required", True))
        default = entry.get("default")
        if default is not None:
            default = str(default)
        out.append(ScriptParam(name=name, type=ptype, required=required, default=default))
    return tuple(out)


# ─── Persistence (author_script) ──────────────────────────────────────────────


def persist_script(
    name: str,
    runtime: str,
    description: str,
    params: tuple[ScriptParam, ...],
    body: str,
    library_dir: Path | None = None,
) -> ScriptSpec:
    """
    Validate and write a new script to the library. Refuses to overwrite
    seed scripts. For cactus-authored scripts, overwriting the same name is
    allowed only if the new body hash differs (content-addressed).
    """
    if not re.fullmatch(r"[a-z][a-z0-9_]{1,63}", name or ""):
        raise ScriptValidationError(f"invalid script name: {name!r}")
    if runtime not in {"shell", "applescript"}:
        raise ScriptValidationError(f"unsupported runtime: {runtime!r}")

    validate_body(runtime, body)

    root = library_dir or SCRIPT_LIBRARY_DIR
    root.mkdir(parents=True, exist_ok=True)
    ext = ".sh" if runtime == "shell" else ".applescript"
    target = root / f"{name}{ext}"

    if target.exists():
        existing = _spec_from_path(target, runtime)
        if existing.author == "seed":
            raise ScriptValidationError(
                f"refusing to overwrite seed script {name!r}"
            )

    final_body = _ensure_frontmatter(
        body=body,
        runtime=runtime,
        name=name,
        description=description,
        params=params,
        author="cactus",
    )
    target.write_text(final_body, encoding="utf-8")
    try:
        target.chmod(0o644)
    except OSError:
        pass
    return _spec_from_path(target, runtime)


def _ensure_frontmatter(
    body: str,
    runtime: str,
    name: str,
    description: str,
    params: tuple[ScriptParam, ...],
    author: str,
) -> str:
    # If the body already contains frontmatter, trust the caller.
    delim = _FRONTMATTER_DELIMS[runtime][0]
    if delim in body.splitlines()[:10]:
        return body.rstrip() + "\n"

    prefix = _COMMENT_PREFIXES[runtime]
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    header_lines = [delim]
    header_lines.append(f"{prefix}name: {name}")
    header_lines.append(f"{prefix}runtime: {runtime}")
    header_lines.append(f"{prefix}description: {description}")
    header_lines.append(f"{prefix}author: {author}")
    header_lines.append(f"{prefix}created_at: {now}")
    header_lines.append(f"{prefix}params:")
    for param in params:
        header_lines.append(f"{prefix}  - name: {param.name}")
        header_lines.append(f"{prefix}    type: {param.type}")
        header_lines.append(f"{prefix}    required: {'true' if param.required else 'false'}")
    header_lines.append(delim)
    header = "\n".join(header_lines) + "\n"

    shebang = ""
    body_text = body
    if runtime == "shell":
        if body.startswith("#!"):
            first_newline = body.find("\n")
            shebang = body[: first_newline + 1]
            body_text = body[first_newline + 1 :]
        else:
            shebang = "#!/bin/bash\n"

    return (shebang + header + body_text).rstrip() + "\n"


# ─── Execution ────────────────────────────────────────────────────────────────


async def run_script(
    name: str,
    args: dict,
    catalog: dict[str, ScriptSpec],
    timeout_seconds: float = 10.0,
) -> ScriptRunResult:
    """Invoke a catalog script. Raises ScriptExecutionError on hard failures."""
    spec = catalog.get(name)
    if spec is None:
        raise ScriptExecutionError(f"unknown script: {name!r}")

    prepared = _prepare_args(spec, args)

    if spec.runtime == "shell":
        env = _shell_env(prepared)
        bash = shutil.which("bash") or "/bin/bash"
        argv = [bash, str(spec.source_path)]
    elif spec.runtime == "applescript":
        osascript = shutil.which("osascript") or "/usr/bin/osascript"
        argv = [osascript, str(spec.source_path), *[_arg_as_str(p, prepared) for p in spec.params]]
        env = None
    else:  # pragma: no cover - validated earlier
        raise ScriptExecutionError(f"unsupported runtime: {spec.runtime}")

    started = time.perf_counter()
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout_seconds)
    except asyncio.TimeoutError as exc:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        raise ScriptExecutionError(f"script {name!r} exceeded {timeout_seconds}s timeout") from exc
    except (OSError, FileNotFoundError) as exc:
        raise ScriptExecutionError(f"failed to launch script {name!r}: {exc}") from exc

    duration_ms = int((time.perf_counter() - started) * 1000)
    return ScriptRunResult(
        name=name,
        returncode=proc.returncode if proc.returncode is not None else -1,
        stdout=stdout.decode("utf-8", errors="replace"),
        stderr=stderr.decode("utf-8", errors="replace"),
        duration_ms=duration_ms,
    )


def _prepare_args(spec: ScriptSpec, args: dict) -> dict:
    out: dict = {}
    for param in spec.params:
        if param.name in args and args[param.name] is not None:
            value = args[param.name]
        elif param.default is not None:
            value = param.default
        elif param.required:
            raise ScriptExecutionError(
                f"script {spec.name!r} missing required arg {param.name!r}"
            )
        else:
            value = ""
        out[param.name] = _coerce_arg(param, value)
    return out


def _coerce_arg(param: ScriptParam, value) -> str:
    text = str(value)
    if param.type == "abs_path":
        p = Path(text).expanduser()
        if not p.is_absolute():
            raise ScriptExecutionError(
                f"param {param.name!r} expects an absolute path; got {text!r}"
            )
        if not p.exists():
            raise ScriptExecutionError(
                f"param {param.name!r} path does not exist: {text!r}"
            )
        return str(p)
    if param.type == "int":
        try:
            int(text)
        except ValueError as exc:
            raise ScriptExecutionError(
                f"param {param.name!r} expects int; got {text!r}"
            ) from exc
        return text
    # generic string: reject NUL bytes only; everything else passes verbatim
    if "\x00" in text:
        raise ScriptExecutionError(f"param {param.name!r} contains NUL byte")
    return text


def _shell_env(prepared: dict) -> dict:
    import os

    base = dict(os.environ)
    # Keep PATH trimmed to common tool locations to reduce surprises.
    base["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    for key, value in prepared.items():
        base[f"ALI_ARG_{key.upper()}"] = value
    return base


def _arg_as_str(param: ScriptParam, prepared: dict) -> str:
    return prepared.get(param.name, param.default or "")


# ─── Convenience ──────────────────────────────────────────────────────────────


def catalog_summary(catalog: dict[str, ScriptSpec], description_chars: int = 120) -> list[dict]:
    """Compact catalog entries suitable for prompt inclusion."""
    out: list[dict] = []
    for spec in catalog.values():
        out.append(
            {
                "name": spec.name,
                "runtime": spec.runtime,
                "description": (spec.description or "")[:description_chars],
                "params": [
                    {"name": p.name, "type": p.type, "required": p.required}
                    for p in spec.params
                ],
            }
        )
    return out


__all__ = [
    "ScriptParam",
    "ScriptSpec",
    "ScriptRunResult",
    "ScriptValidationError",
    "ScriptExecutionError",
    "SCRIPT_LIBRARY_DIR",
    "VALID_PARAM_TYPES",
    "load_catalog",
    "parse_frontmatter",
    "persist_script",
    "run_script",
    "validate_body",
    "catalog_summary",
]

# Keep field import usage to avoid "imported but unused" lint from default
# dataclass factories during future edits.
_ = field
