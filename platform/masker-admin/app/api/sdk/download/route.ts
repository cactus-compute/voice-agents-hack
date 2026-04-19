import { NextRequest, NextResponse } from "next/server";

const POLICY_RULES: Record<string, { entity: string; action: string; rehydration: boolean }[]> = {
  HIPAA: [
    { entity: "NAME",     action: "mask",     rehydration: true  },
    { entity: "DOB",      action: "mask",     rehydration: true  },
    { entity: "SSN",      action: "redact",   rehydration: false },
    { entity: "MRN",      action: "tokenize", rehydration: true  },
    { entity: "PHONE",    action: "mask",     rehydration: true  },
    { entity: "ADDRESS",  action: "mask",     rehydration: true  },
    { entity: "EMAIL",    action: "mask",     rehydration: true  },
    { entity: "INS_ID",   action: "mask",     rehydration: true  },
    { entity: "DIAGNOSIS",action: "redact",   rehydration: false },
  ],
  GDPR: [
    { entity: "NAME",       action: "mask",   rehydration: true  },
    { entity: "EMAIL",      action: "mask",   rehydration: true  },
    { entity: "IP_ADDRESS", action: "redact", rehydration: false },
    { entity: "LOCATION",   action: "mask",   rehydration: true  },
    { entity: "PHONE",      action: "mask",   rehydration: true  },
  ],
  PCI: [
    { entity: "CC_NUMBER",     action: "block",  rehydration: false },
    { entity: "CC_EXP",        action: "block",  rehydration: false },
    { entity: "CC_CVV",        action: "block",  rehydration: false },
    { entity: "BANK_ACCOUNT",  action: "redact", rehydration: false },
  ],
  Custom: [
    { entity: "NAME",  action: "mask",  rehydration: true },
    { entity: "EMAIL", action: "mask",  rehydration: true },
  ],
};

function buildPythonSnippet(apiKey: string, framework: string, orgName: string): string {
  const rules = POLICY_RULES[framework] ?? POLICY_RULES.Custom;
  const rulesRepr = rules
    .map((r) => `    PolicyRule(entity="${r.entity}", action="${r.action}", rehydration=${r.rehydration ? "True" : "False"})`)
    .join(",\n");

  return `"""
Masker SDK — pre-configured for ${orgName}
Framework: ${framework}
Generated: ${new Date().toISOString()}

Install:
    pip install masker-sdk

Docs: https://docs.masker.io
"""

from masker import MaskerClient, Policy, PolicyRule

# Initialise the client — keep your API key in an environment variable
client = MaskerClient(api_key="${apiKey}")

# ${framework} policy — auto-generated from your dashboard settings
policy = Policy(
  name="${framework} Base",
  framework="${framework}",
  rules=[
${rulesRepr}
  ]
)

# ── Basic usage ───────────────────────────────────────────────────────────────

def process_transcript(raw_text: str) -> str:
    """Mask PII in a transcript before sending to your LLM."""
    result = client.mask(text=raw_text, policy=policy)
    print(f"Entities detected: {len(result.entity_spans)}")
    print(f"Risk level: {result.risk_level}")
    return result.redacted_text


def rehydrate_response(masked_response: str, session_id: str) -> str:
    """Restore original values in the model response (where policy allows)."""
    return client.rehydrate(text=masked_response, session_id=session_id)


# ── Voice agent integration ───────────────────────────────────────────────────

def on_transcript(raw_transcript: str) -> dict:
    """
    Drop this into your voice agent's transcript handler.
    Returns the masked transcript + audit metadata.
    """
    result = client.mask(text=raw_transcript, policy=policy)

    # Audit log is written automatically to your Masker dashboard
    return {
        "redacted": result.redacted_text,
        "session_id": result.session_id,
        "risk_level": result.risk_level,
        "entities": [
            {"type": e.type, "action": e.action, "masked": e.masked}
            for e in result.entity_spans
        ],
    }


# ── Example ───────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    sample = "Hi, my name is Sarah Johnson. My SSN is 123-45-6789 and DOB is 03/15/1982."
    masked = process_transcript(sample)
    print("Masked:", masked)
`;
}

function buildJsonConfig(apiKey: string, framework: string, orgName: string): string {
  const rules = POLICY_RULES[framework] ?? POLICY_RULES.Custom;
  return JSON.stringify(
    {
      masker: {
        api_key: apiKey,
        org: orgName,
        framework,
        api_base: "https://api.masker.io/v1",
        policy: {
          name: `${framework} Base`,
          version: "1.0",
          rules,
        },
        options: {
          audit_logging: true,
          fail_safe: "block",
          rehydration_ttl_seconds: 3600,
        },
      },
    },
    null,
    2
  );
}

export async function GET(req: NextRequest) {
  const { searchParams } = req.nextUrl;
  const format = searchParams.get("format") ?? "python";
  const apiKey = searchParams.get("key") ?? "msk_live_xxxx";
  const framework = searchParams.get("framework") ?? "HIPAA";
  const org = searchParams.get("org") ?? "My Org";

  if (format === "python") {
    const content = buildPythonSnippet(apiKey, framework, org);
    return new NextResponse(content, {
      headers: {
        "Content-Type": "text/x-python",
        "Content-Disposition": 'attachment; filename="masker_config.py"',
      },
    });
  }

  if (format === "json") {
    const content = buildJsonConfig(apiKey, framework, org);
    return new NextResponse(content, {
      headers: {
        "Content-Type": "application/json",
        "Content-Disposition": 'attachment; filename="masker_config.json"',
      },
    });
  }

  return NextResponse.json({ error: "Unknown format" }, { status: 400 });
}
