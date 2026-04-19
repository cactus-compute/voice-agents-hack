"""Unit tests for the script library runtime."""

from __future__ import annotations

import asyncio
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from executors.local import script_runtime
from executors.local.script_runtime import (
    SCRIPT_LIBRARY_DIR,
    ScriptParam,
    ScriptValidationError,
    catalog_summary,
    load_catalog,
    parse_frontmatter,
    persist_script,
    run_script,
    validate_body,
)


class SeedCatalogTests(unittest.TestCase):
    def test_load_catalog_includes_seed_reveal_in_finder(self) -> None:
        catalog = load_catalog()
        self.assertIn("reveal_in_finder", catalog)
        spec = catalog["reveal_in_finder"]
        self.assertEqual(spec.runtime, "shell")
        self.assertEqual(spec.author, "seed")
        self.assertTrue(any(p.name == "path" and p.type == "abs_path" for p in spec.params))

    def test_catalog_summary_shape(self) -> None:
        catalog = load_catalog()
        summary = catalog_summary(catalog)
        self.assertTrue(any(entry["name"] == "reveal_in_finder" for entry in summary))
        reveal = next(entry for entry in summary if entry["name"] == "reveal_in_finder")
        self.assertEqual(reveal["runtime"], "shell")
        self.assertIsInstance(reveal["description"], str)
        self.assertLessEqual(len(reveal["description"]), 120)


class ShellAllowlistTests(unittest.TestCase):
    def test_accepts_reveal_pattern(self) -> None:
        body = '#!/bin/bash\nset -eu\nopen -R "$ALI_ARG_PATH"\n'
        validate_body("shell", body)  # does not raise

    def test_rejects_rm(self) -> None:
        with self.assertRaises(ScriptValidationError):
            validate_body("shell", "rm -rf /tmp/x")

    def test_rejects_backticks(self) -> None:
        with self.assertRaises(ScriptValidationError):
            validate_body("shell", 'echo "`whoami`"')

    def test_rejects_command_substitution(self) -> None:
        with self.assertRaises(ScriptValidationError):
            validate_body("shell", 'echo "$(whoami)"')

    def test_rejects_network_tool(self) -> None:
        with self.assertRaises(ScriptValidationError):
            validate_body("shell", "curl https://example.com")

    def test_rejects_unsafe_redirect(self) -> None:
        with self.assertRaises(ScriptValidationError):
            validate_body("shell", "echo hi > /tmp/out")


class AppleScriptAllowlistTests(unittest.TestCase):
    def test_allows_finder_tell(self) -> None:
        body = (
            '-- ---\n-- name: demo\n-- runtime: applescript\n-- ---\n'
            'tell application "Finder"\n    activate\nend tell\n'
        )
        validate_body("applescript", body)

    def test_rejects_do_shell_script(self) -> None:
        with self.assertRaises(ScriptValidationError):
            validate_body(
                "applescript",
                'tell application "Finder"\n    do shell script "rm -rf /"\nend tell\n',
            )

    def test_rejects_unknown_app(self) -> None:
        with self.assertRaises(ScriptValidationError):
            validate_body(
                "applescript",
                'tell application "Safari"\n    activate\nend tell\n',
            )


class FrontmatterTests(unittest.TestCase):
    def test_parse_shell_frontmatter(self) -> None:
        body = (
            "#!/bin/bash\n"
            "# ---\n"
            "# name: demo\n"
            "# runtime: shell\n"
            "# description: Demo script\n"
            "# author: seed\n"
            "# params:\n"
            "#   - name: path\n"
            "#     type: abs_path\n"
            "#     required: true\n"
            "# ---\n"
            "echo hi\n"
        )
        meta = parse_frontmatter(body, "shell")
        self.assertEqual(meta["name"], "demo")
        self.assertEqual(meta["runtime"], "shell")
        self.assertEqual(len(meta["params"]), 1)
        self.assertEqual(meta["params"][0]["name"], "path")
        self.assertEqual(meta["params"][0]["type"], "abs_path")


class PersistAndRunTests(unittest.TestCase):
    def test_refuses_to_overwrite_seed(self) -> None:
        with self.assertRaises(ScriptValidationError):
            persist_script(
                name="reveal_in_finder",
                runtime="shell",
                description="malicious overwrite",
                params=(ScriptParam(name="path", type="abs_path", required=True),),
                body="echo hi\n",
            )

    def test_persist_and_load_cactus_script(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            spec = persist_script(
                name="say_hi",
                runtime="shell",
                description="Print a greeting.",
                params=(ScriptParam(name="name", type="string", required=True),),
                body='echo "hello $ALI_ARG_NAME"\n',
                library_dir=root,
            )
            self.assertEqual(spec.author, "cactus")
            catalog = load_catalog(root)
            self.assertIn("say_hi", catalog)

    def test_run_script_invokes_expected_argv(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            spec = persist_script(
                name="say_hi",
                runtime="shell",
                description="Greet",
                params=(ScriptParam(name="name", type="string", required=True),),
                body='echo "hello $ALI_ARG_NAME"\n',
                library_dir=root,
            )
            catalog = {"say_hi": spec}

            fake_proc = mock.AsyncMock()
            fake_proc.communicate = mock.AsyncMock(return_value=(b"hello world\n", b""))
            fake_proc.returncode = 0
            captured: dict = {}

            async def _fake_exec(*argv, env=None, stdout=None, stderr=None):
                captured["argv"] = argv
                captured["env"] = env
                return fake_proc

            with mock.patch.object(
                script_runtime.asyncio,
                "create_subprocess_exec",
                side_effect=_fake_exec,
            ):
                result = asyncio.run(
                    run_script("say_hi", {"name": "world"}, catalog)
                )

            self.assertTrue(result.ok())
            self.assertEqual(captured["argv"][-1], str(spec.source_path))
            self.assertEqual(captured["env"]["ALI_ARG_NAME"], "world")

    def test_run_script_abs_path_requires_existing_file(self) -> None:
        spec_catalog = load_catalog()
        with self.assertRaises(script_runtime.ScriptExecutionError):
            asyncio.run(
                run_script(
                    "reveal_in_finder",
                    {"path": "/tmp/definitely-does-not-exist-xyz.pdf"},
                    spec_catalog,
                )
            )


if __name__ == "__main__":
    unittest.main()
