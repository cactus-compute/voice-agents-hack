"""Tiny usage example for the Codex privacy pipeline.

Run:
    python -m masker.example_privacy
"""

from __future__ import annotations

import json

from .privacy import analyze_transcript


def main() -> None:
    text = "My doctor said I have chest pain and my insurance ID is BCBS-887421."
    result = analyze_transcript(text, policy_name="hipaa_clinical_context")

    print("INPUT")
    print(text)
    print("\nDETECTION")
    print(json.dumps(result.detection.to_dict(), indent=2))
    print("\nDECISION")
    print(json.dumps(result.policy.to_dict(), indent=2))
    print("\nMASKED")
    print(result.masked.text)
    print("\nTIMINGS")
    print(json.dumps(result.timings.to_dict(), indent=2))


if __name__ == "__main__":
    main()
