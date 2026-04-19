"""Tests for the hash-chained HIPAA audit log.

These tests pin down the four properties an auditor would check:

  1. The chain starts at GENESIS.
  2. Each entry's prev_hash links to the previous entry's entry_hash.
  3. Payloads never contain raw PHI (the guardrail trips on accidental leaks).
  4. A single byte changed mid-file makes verify_chain() report INVALID with
     the broken line number.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import masker
from masker import Tracer, auto_attach, filter_input
from masker.contracts import GENESIS_HASH, AuditEntry, compute_entry_hash


class _AuditFileHarness:
    """Context manager that hands you a fresh audit.jsonl path and tears
    down the global tracer at exit so tests don't leak state into each
    other."""

    def __init__(self) -> None:
        self._tmp: tempfile.TemporaryDirectory | None = None
        self.path: Path | None = None

    def __enter__(self) -> Path:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "audit.jsonl"
        return self.path

    def __exit__(self, *exc: object) -> None:
        masker._set_global_tracer(None)
        if self._tmp is not None:
            self._tmp.cleanup()


class ChainGenesisTests(unittest.TestCase):
    def test_first_entry_links_to_genesis(self):
        with _AuditFileHarness() as path:
            auto_attach(audit_path=path)
            filter_input("What's the weather tomorrow?")

            lines = path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 1)
            entry = json.loads(lines[0])
            self.assertEqual(entry["prev_hash"], GENESIS_HASH)
            self.assertEqual(len(entry["entry_hash"]), 64)  # SHA-256 hex


class ChainLinkTests(unittest.TestCase):
    def test_each_entry_links_to_previous(self):
        with _AuditFileHarness() as path:
            auto_attach(audit_path=path)
            filter_input("What's the weather tomorrow?")
            filter_input("My SSN is 123-45-6789.")
            filter_input("Email me at jane@example.com.")

            lines = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(len(lines), 3)
            self.assertEqual(lines[0]["prev_hash"], GENESIS_HASH)
            self.assertEqual(lines[1]["prev_hash"], lines[0]["entry_hash"])
            self.assertEqual(lines[2]["prev_hash"], lines[1]["entry_hash"])

            result = Tracer.verify_chain(path)
            self.assertTrue(result.valid)
            self.assertEqual(result.total_entries, 3)
            self.assertIsNone(result.broken_at_line)


class PayloadGuardrailTests(unittest.TestCase):
    def test_payload_never_contains_raw_phi(self):
        """High-signal: filter_input("My SSN is 123-45-6789.") MUST NOT write
        '123-45-6789' anywhere in the audit file. Only entity types, spans,
        lengths, and rationales should make it to disk."""
        with _AuditFileHarness() as path:
            auto_attach(audit_path=path)
            filter_input("My SSN is 123-45-6789 and email jane@example.com.")

            content = path.read_text(encoding="utf-8")
            self.assertNotIn("123-45-6789", content)
            self.assertNotIn("jane@example.com", content)

    def test_evidence_rejects_raw_phi_in_payload(self):
        """If a future caller tries to stash raw PII into the payload dict,
        the tracer must refuse — that's a control failure, not a soft warning.
        """
        with _AuditFileHarness() as path:
            tracer = Tracer(audit_path=path, surface="test")
            with self.assertRaises(ValueError):
                tracer.evidence(
                    stage="policy",
                    message="oops",
                    decision="local-only",
                    controls=["164.312(b)"],
                    payload={"leaky_value": "SSN 123-45-6789 is here"},
                )


class TamperDetectionTests(unittest.TestCase):
    def test_single_byte_flip_breaks_chain(self):
        with _AuditFileHarness() as path:
            auto_attach(audit_path=path)
            filter_input("What's the weather tomorrow?")
            filter_input("My SSN is 123-45-6789.")
            filter_input("Email me at jane@example.com.")

            self.assertTrue(Tracer.verify_chain(path).valid)

            # Tamper with the second row by flipping one character of its
            # rationale. The stored entry_hash for that row stays the same,
            # but the recomputed hash will differ — verify_chain() must catch
            # it AND point at line 2.
            lines = path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 3)
            tampered = json.loads(lines[1])
            payload = tampered["payload"]
            payload["rationale"] = (payload.get("rationale") or "") + " (mutated)"
            tampered["payload"] = payload
            lines[1] = json.dumps(tampered, sort_keys=True, separators=(",", ":"))
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")

            result = Tracer.verify_chain(path)
            self.assertFalse(result.valid)
            self.assertEqual(result.broken_at_line, 2)
            self.assertIsNotNone(result.expected_hash)
            self.assertIsNotNone(result.computed_hash)
            self.assertNotEqual(result.expected_hash, result.computed_hash)


class HashHelperTests(unittest.TestCase):
    """Belt-and-suspenders tests on the hash primitive itself — if these
    drift, every chain in the wild becomes unverifiable."""

    def test_hash_is_deterministic_regardless_of_key_order(self):
        a = compute_entry_hash({"b": 1, "a": 2})
        b = compute_entry_hash({"a": 2, "b": 1})
        self.assertEqual(a, b)

    def test_hash_changes_when_payload_changes(self):
        a = compute_entry_hash({"a": 1})
        b = compute_entry_hash({"a": 2})
        self.assertNotEqual(a, b)

    def test_audit_entry_to_jsonl_roundtrips(self):
        body = {
            "ts": "2026-04-18T00:00:00+00:00",
            "surface": "test",
            "stage": "policy",
            "message": "t",
            "elapsed_ms": 0.0,
            "decision": "safe-to-send",
            "policy": "hipaa_base",
            "regulation": "hipaa",
            "controls": ["164.312(b)"],
            "payload": {"x": 1},
            "prev_hash": GENESIS_HASH,
        }
        body["entry_hash"] = compute_entry_hash(body)
        entry = AuditEntry(**body)
        roundtrip = json.loads(entry.to_jsonl())
        self.assertEqual(roundtrip["entry_hash"], body["entry_hash"])
        self.assertEqual(roundtrip["prev_hash"], GENESIS_HASH)


if __name__ == "__main__":
    unittest.main()
