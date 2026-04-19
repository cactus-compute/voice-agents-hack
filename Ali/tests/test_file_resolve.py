"""
Unit tests for the multi-role Cactus+Spotlight file resolver.

Cactus and `mdfind` are monkeypatched so these tests run deterministically on
any OS. The walk fallback exercises a real temp-directory tree.
"""

from __future__ import annotations

import asyncio
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from executors.local.file_index import bounded_walk, validate_predicate
from intent import file_resolve as resolver_mod
from intent.file_resolve import enrich_intent_with_resolved_files
from intent.schema import IntentObject, KnownGoal


def _apply_intent() -> IntentObject:
    return IntentObject(
        goal=KnownGoal.APPLY_TO_JOB,
        target={"type": "url", "value": "apply.ycombinator.com"},
        uses_local_data=["resume"],
        requires_browser=True,
        requires_submission=True,
        slots={},
        raw_transcript="apply to YC using my resume",
    )


def _find_file_intent() -> IntentObject:
    return IntentObject(
        goal=KnownGoal.FIND_FILE,
        target={"type": "file", "value": "taxes"},
        uses_local_data=[],
        requires_browser=False,
        requires_submission=False,
        slots={"file_query": "taxes"},
        raw_transcript="find my 2024 taxes pdf",
    )


def _email_intent() -> IntentObject:
    return IntentObject(
        goal=KnownGoal.SEND_EMAIL,
        target={"type": "contact", "value": ""},
        uses_local_data=["attachment", "resume"],
        requires_browser=False,
        requires_submission=True,
        slots={"file_query": "deck"},
        raw_transcript="email me the attachment and resume",
    )


class PredicateValidationTests(unittest.TestCase):
    def test_rejects_shell_metacharacters(self) -> None:
        for predicate in ["foo; rm -rf /", "`whoami`", "$(echo nope)", "x && y", "x\ny"]:
            with self.subTest(predicate=predicate):
                self.assertIsNone(validate_predicate(predicate))

    def test_rejects_overly_long(self) -> None:
        self.assertIsNone(validate_predicate("a" * 500))

    def test_accepts_simple_mdquery(self) -> None:
        self.assertEqual(
            validate_predicate('kMDItemFSName == "*resume*"c'),
            'kMDItemFSName == "*resume*"c',
        )


class ResolverBehaviorTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tempdir = tempfile.TemporaryDirectory()
        self.tmp_root = Path(self._tempdir.name).resolve()
        self.addCleanup(self._tempdir.cleanup)

        self._patches: list[tuple[object, str, object]] = []
        self._patch(resolver_mod, "CACTUS_CLI", "/usr/bin/cactus-stub")
        self._patch(resolver_mod, "FILE_RESOLVER_ENABLED", True)
        self._patch(resolver_mod, "FILE_RESOLVER_ALIAS_FIRST", False)
        self._patch(resolver_mod, "FILE_RESOLVER_USE_SPOTLIGHT", True)
        self._patch(resolver_mod, "FILE_SEARCH_ROOTS", [self.tmp_root])
        self._patch(resolver_mod, "FILE_PREDICATE_MAX_ROUNDS", 2)
        self._patch(resolver_mod, "FILE_MDFIND_MAX_RESULTS", 40)
        self._patch(resolver_mod, "FILE_WALK_MAX_FILES", 50)
        self._patch(resolver_mod, "FILE_WALK_MAX_DEPTH", 3)

    def tearDown(self) -> None:
        for target, name, original in reversed(self._patches):
            setattr(target, name, original)

    def _patch(self, target: object, name: str, value: object) -> None:
        self._patches.append((target, name, getattr(target, name)))
        setattr(target, name, value)

    def _write_file(self, relpath: str) -> Path:
        path = self.tmp_root / relpath
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"hello")
        return path

    # ── Multi-role resolution ──────────────────────────────────────────────

    def test_multi_role_resolves_resume_and_attachment(self) -> None:
        resume = self._write_file("resume.pdf")
        deck = self._write_file("pitch-deck.pdf")
        intent = _email_intent()

        async def _fake_mdfind(predicate, only_in, limit):
            return [resume] if "resume" in predicate else [deck]

        async def _fake_cactus(prompt, state):
            role_hint = "resume" if "Role: resume" in prompt else "attachment"
            if "chosen_path" in prompt:
                chosen = resume if role_hint == "resume" else deck
                return {"chosen_path": str(chosen), "confidence": "high"}
            pattern = "*resume*" if role_hint == "resume" else "*deck*"
            return {"predicate": f'kMDItemFSName == "{pattern}"', "only_in_root_index": 0}

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _fake_cactus)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))

        resolved = intent.slots["resolved_local_files"]
        self.assertEqual(resolved.get("resume"), str(resume))
        self.assertEqual(resolved.get("attachment"), str(deck))
        self.assertEqual(intent.slots.get("resume_path"), str(resume))

    def test_find_file_writes_found_key(self) -> None:
        target = self._write_file("taxes-2024.pdf")
        intent = _find_file_intent()

        async def _fake_mdfind(predicate, only_in, limit):
            return [target]

        async def _fake_cactus(prompt, state):
            if "chosen_path" in prompt:
                return {"chosen_path": str(target), "confidence": "high"}
            return {"predicate": 'kMDItemFSName == "*taxes*"', "only_in_root_index": 0}

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _fake_cactus)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))

        self.assertEqual(intent.slots["resolved_local_files"].get("found"), str(target))
        self.assertNotIn("resume_path", intent.slots)

    def test_idempotent_after_first_run(self) -> None:
        target = self._write_file("resume.pdf")
        intent = _apply_intent()
        intent.slots["resolved_local_files"] = {"resume": str(target)}

        calls: list[str] = []

        async def _boom(*args, **kwargs):
            calls.append("cactus")
            return None

        self._patch(resolver_mod, "_cactus_json", _boom)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))
        self.assertEqual(calls, [])

    # ── Branches ───────────────────────────────────────────────────────────

    def test_single_candidate_still_invokes_picker(self) -> None:
        candidate = self._write_file("resume.pdf")
        intent = _apply_intent()

        picker_calls: list[str] = []

        async def _fake_mdfind(predicate, only_in, limit):
            return [candidate]

        async def _fake_cactus(prompt, state):
            if "chosen_path" in prompt:
                picker_calls.append(prompt)
                return {"chosen_path": str(candidate), "confidence": "high"}
            return {"predicate": 'kMDItemFSName == "*resume*"', "only_in_root_index": 0}

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _fake_cactus)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))

        self.assertEqual(
            intent.slots["resolved_local_files"]["resume"], str(candidate)
        )
        self.assertEqual(len(picker_calls), 1)

    def test_picker_abstain_triggers_refine(self) -> None:
        junk = self._write_file("resume_template.plist")
        real = self._write_file("resume-final.pdf")
        intent = _apply_intent()

        predicate_rounds: list[str] = []
        picker_calls: list[list[Path]] = []

        async def _fake_mdfind(predicate, only_in, limit):
            if "plist" in predicate or "template" in predicate:
                return [junk]
            return [real]

        async def _fake_cactus(prompt, state):
            if "chosen_path" in prompt:
                if str(junk) in prompt:
                    picker_calls.append([junk])
                    return {
                        "chosen_path": None,
                        "confidence": "low",
                        "reason": "looks like a system template",
                    }
                picker_calls.append([real])
                return {"chosen_path": str(real), "confidence": "high"}
            if not predicate_rounds:
                predicate_rounds.append("first")
                return {
                    "predicate": 'kMDItemFSName == "*template*"',
                    "only_in_root_index": 0,
                }
            predicate_rounds.append("second")
            return {
                "predicate": 'kMDItemFSName == "*resume-final*"',
                "only_in_root_index": 0,
            }

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _fake_cactus)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))

        self.assertEqual(
            intent.slots["resolved_local_files"].get("resume"), str(real)
        )
        self.assertEqual(len(predicate_rounds), 2)
        self.assertEqual(len(picker_calls), 2)

    def test_picker_low_confidence_treated_as_abstain(self) -> None:
        guess = self._write_file("resumes.zip")
        real = self._write_file("resume-final.pdf")
        intent = _apply_intent()

        round_counter = {"n": 0}

        async def _fake_mdfind(predicate, only_in, limit):
            if "resumes" in predicate:
                return [guess]
            return [real]

        async def _fake_cactus(prompt, state):
            if "chosen_path" in prompt:
                if str(guess) in prompt:
                    return {
                        "chosen_path": str(guess),
                        "confidence": "low",
                        "reason": "filename only partial match",
                    }
                return {"chosen_path": str(real), "confidence": "high"}
            round_counter["n"] += 1
            if round_counter["n"] == 1:
                return {
                    "predicate": 'kMDItemFSName == "*resumes*"',
                    "only_in_root_index": 0,
                }
            return {
                "predicate": 'kMDItemFSName == "*resume-final*"',
                "only_in_root_index": 0,
            }

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _fake_cactus)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))

        self.assertEqual(
            intent.slots["resolved_local_files"].get("resume"), str(real)
        )
        self.assertEqual(round_counter["n"], 2)

    def test_large_result_set_still_reaches_picker(self) -> None:
        many = [self._write_file(f"resume-{i:02}.pdf") for i in range(50)]
        target = many[0]
        intent = _apply_intent()

        picker_prompts: list[str] = []

        async def _fake_mdfind(predicate, only_in, limit):
            return many

        async def _fake_cactus(prompt, state):
            if "chosen_path" in prompt:
                picker_prompts.append(prompt)
                return {"chosen_path": str(target), "confidence": "high"}
            return {
                "predicate": 'kMDItemFSName == "*resume*"',
                "only_in_root_index": 0,
            }

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _fake_cactus)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))

        self.assertEqual(
            intent.slots["resolved_local_files"].get("resume"), str(target)
        )
        self.assertEqual(len(picker_prompts), 1)
        prompt = picker_prompts[0]
        self.assertIn(str(target), prompt)
        # Only the top 12 (Spotlight order) should appear in the pick prompt.
        self.assertIn(str(many[11]), prompt)
        self.assertNotIn(str(many[12]), prompt)

    def test_picker_rejects_out_of_set_path(self) -> None:
        a = self._write_file("resume-2022.pdf")
        b = self._write_file("resume-2024.pdf")
        intent = _apply_intent()

        picker_calls = {"n": 0}

        async def _fake_mdfind(predicate, only_in, limit):
            return [a, b]

        async def _fake_cactus(prompt, state):
            if "chosen_path" in prompt:
                picker_calls["n"] += 1
                return {
                    "chosen_path": "/tmp/not-in-candidates.pdf",
                    "confidence": "high",
                }
            return {"predicate": 'kMDItemFSName == "*resume*"', "only_in_root_index": 0}

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _fake_cactus)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))

        self.assertEqual(intent.slots["resolved_local_files"], {})
        # Out-of-set is surfaced as abstain, so every predicate round in the
        # loop retries up to FILE_PREDICATE_MAX_ROUNDS (=2 in this test's
        # setUp); the walk fallback then invokes the picker once more.
        self.assertEqual(picker_calls["n"], 3)

    def test_naive_mdfind_prefers_documents_over_images(self) -> None:
        svg = self._write_file("resume.svg")
        pdf = self._write_file("resume-final.pdf")
        docx = self._write_file("resume-old.docx")
        intent = _find_file_intent()
        intent.slots["file_query"] = "resume"

        self._patch(resolver_mod, "CACTUS_CLI", None)

        async def _fake_mdfind(predicate, only_in, limit):
            return [svg, pdf, docx]

        async def _boom(*args, **kwargs):  # pragma: no cover
            raise AssertionError("Cactus must not fire")

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _boom)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))
        chosen = intent.slots["resolved_local_files"].get("found")
        self.assertIsNotNone(chosen)
        self.assertTrue(chosen.endswith((".pdf", ".docx")), f"picked non-document {chosen!r}")
        self.assertFalse(chosen.endswith(".svg"), "should not pick SVG for a document query")

    def test_naive_mdfind_fallback_without_cactus(self) -> None:
        target = self._write_file("resume-final.pdf")
        intent = _find_file_intent()

        self._patch(resolver_mod, "CACTUS_CLI", None)

        captured_terms: list[str] = []

        async def _fake_mdfind(predicate, only_in, limit):
            m = __import__("re").search(r'"\*([^"*]+)\*"', predicate)
            if m:
                captured_terms.append(m.group(1))
            return [target] if "resume" in predicate or "final" in predicate else []

        async def _boom(*args, **kwargs):  # pragma: no cover - should not fire
            raise AssertionError("Cactus must not be invoked when CLI is absent")

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _boom)

        intent.slots["file_query"] = "resume final"
        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))

        self.assertEqual(
            intent.slots["resolved_local_files"].get("found"), str(target)
        )
        self.assertTrue(captured_terms, "expected at least one naive mdfind call")

    def test_walk_fallback_on_empty_mdfind(self) -> None:
        hit = self._write_file("deep/resume-backup.pdf")
        intent = _apply_intent()

        async def _fake_mdfind(predicate, only_in, limit):
            return []

        async def _fake_cactus(prompt, state):
            if "chosen_path" in prompt:
                return {"chosen_path": str(hit), "confidence": "high"}
            return {"predicate": 'kMDItemFSName == "*resume*"', "only_in_root_index": 0}

        self._patch(resolver_mod, "run_mdfind", _fake_mdfind)
        self._patch(resolver_mod, "_cactus_json", _fake_cactus)

        asyncio.run(enrich_intent_with_resolved_files(intent, intent.raw_transcript))
        self.assertEqual(intent.slots["resolved_local_files"]["resume"], str(hit))


class BoundedWalkTests(unittest.TestCase):
    def test_bounded_walk_limits_and_skips(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            (root / "a.txt").write_text("a")
            (root / "b.txt").write_text("b")
            nested = root / "deep" / "deeper" / "deepest"
            nested.mkdir(parents=True)
            (nested / "too-deep.txt").write_text("nope")
            hidden = root / ".git"
            hidden.mkdir()
            (hidden / "ignored.txt").write_text("ignored")

            results = bounded_walk([root], limit=5, max_depth=2)
            names = {p.name for p in results}
            self.assertIn("a.txt", names)
            self.assertIn("b.txt", names)
            self.assertNotIn("ignored.txt", names)
            self.assertNotIn("too-deep.txt", names)


if __name__ == "__main__":
    unittest.main()
