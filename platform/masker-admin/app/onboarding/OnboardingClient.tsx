"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Check, ChevronRight, KeyRound, Shield, Download, Lock } from "lucide-react";
import { cn } from "@/lib/utils";

type Framework = "HIPAA" | "GDPR" | "PCI" | "Custom";

const STEPS = [
  { id: 1, label: "Workspace" },
  { id: 2, label: "KMS" },
  { id: 3, label: "API Key" },
  { id: 4, label: "Download SDK" },
];

const FRAMEWORKS: { value: Framework; label: string; desc: string }[] = [
  { value: "HIPAA", label: "HIPAA", desc: "Healthcare — PHI, MRN, clinical data" },
  { value: "GDPR", label: "GDPR", desc: "EU residents — PII, consent, residency" },
  { value: "PCI", label: "PCI DSS", desc: "Payments — card numbers, CVV, bank data" },
  { value: "Custom", label: "Custom", desc: "Define your own entity rules" },
];

const PERMISSIONS = [
  { value: "sessions:read", label: "Read sessions" },
  { value: "sessions:write", label: "Write session events" },
  { value: "audit:read", label: "Read audit logs" },
  { value: "policies:read", label: "Read policies" },
];

function StepIndicator({ current }: { current: number }) {
  return (
    <div className="flex items-center gap-0 mb-10">
      {STEPS.map((step, i) => (
        <div key={step.id} className="flex items-center">
          <div className="flex flex-col items-center gap-1.5">
            <div className={cn(
              "w-8 h-8 rounded-full flex items-center justify-center text-[13px] font-semibold transition-colors",
              step.id < current ? "bg-[#0d0f12] text-white" :
              step.id === current ? "bg-indigo-600 text-white" :
              "bg-[#f3f4f6] text-[#9ca3af]"
            )}>
              {step.id < current ? <Check className="w-4 h-4" /> : step.id}
            </div>
            <span className={cn(
              "text-[11px] font-medium whitespace-nowrap",
              step.id === current ? "text-[#0d0f12]" : "text-[#9ca3af]"
            )}>
              {step.label}
            </span>
          </div>
          {i < STEPS.length - 1 && (
            <div className={cn(
              "h-px w-16 mx-2 mb-5 transition-colors",
              step.id < current ? "bg-[#0d0f12]" : "bg-[#e5e7eb]"
            )} />
          )}
        </div>
      ))}
    </div>
  );
}

export function OnboardingClient() {
  const router = useRouter();
  const supabase = createClient();

  const [step, setStep] = useState(1);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Step 1 — workspace
  const [orgName, setOrgName] = useState("");
  const [framework, setFramework] = useState<Framework>("HIPAA");
  const [orgId, setOrgId] = useState<string | null>(null);

  // Step 2 — KMS
  const [kmsProvider, setKmsProvider] = useState<"masker" | "byok">("masker");
  

  // Step 3 — API key
  const [keyLabel, setKeyLabel] = useState("Production");
  const [permissions, setPermissions] = useState(["sessions:read", "sessions:write", "audit:read"]);
  const [createdKey, setCreatedKey] = useState<{ prefix: string; fullKey: string } | null>(null);

  function slugify(s: string) {
    return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  }

  async function createWorkspace() {
    setLoading(true);
    setError(null);
    try {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) throw new Error("Not authenticated");

      const slug = slugify(orgName);
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any)
        .from("orgs")
        .insert({ name: orgName, slug, owner_id: user.id, framework })
        .select()
        .single();

      if (error) throw error;
      setOrgId(data.id);
      setStep(2);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to create workspace");
    } finally {
      setLoading(false);
    }
  }

  async function setupKms() {
    setLoading(true);
    setError(null);
    try {
      if (!orgId) throw new Error("No org");

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase as any)
        .from("kms_keys")
        .insert({
          org_id: orgId,
          alias: `masker/${slugify(orgName)}/primary`,
          scope: "All sessions",
          region: "us-east-1",
          rotation_cadence: "90 days",
          last_rotated_at: new Date().toISOString(),
          status: "active",
          provider: kmsProvider,
        })
        .select()
        .single();

      if (error) throw error;
      
      setStep(3);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to setup KMS");
    } finally {
      setLoading(false);
    }
  }

  async function createApiKey() {
    setLoading(true);
    setError(null);
    try {
      if (!orgId) throw new Error("No org");

      // Generate key client-side for display — hash stored server-side via API route
      const res = await fetch("/api/keys", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ label: keyLabel, permissions, environment: "production", org_id: orgId }),
      });
      if (!res.ok) throw new Error("Failed to create API key");
      const data = await res.json();
      setCreatedKey({ prefix: data.prefix, fullKey: data.full_key ?? `${data.prefix}_${"x".repeat(32)}` });
      setStep(4);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to create API key");
    } finally {
      setLoading(false);
    }
  }

  function togglePermission(p: string) {
    setPermissions((prev) =>
      prev.includes(p) ? prev.filter((x) => x !== p) : [...prev, p]
    );
  }

  return (
    <div className="min-h-screen bg-[#f8fafc] flex items-center justify-center p-6">
      <div className="w-full max-w-xl">
        {/* Logo */}
        <div className="flex items-center gap-2 mb-10">
          <span className="text-xl">🛡️</span>
          <span className="font-semibold text-[#0d0f12]">Masker</span>
        </div>

        <StepIndicator current={step} />

        <div className="bg-white rounded-xl border border-[#e5e7eb] p-8">

          {/* ── Step 1: Workspace ── */}
          {step === 1 && (
            <div>
              <h2 className="text-[18px] font-semibold text-[#0d0f12] mb-1">Create your workspace</h2>
              <p className="text-[13px] text-[#6b7280] mb-6">This is your organisation in Masker. You can invite team members later.</p>

              <div className="space-y-4">
                <div>
                  <label className="block text-[12px] font-medium text-[#374151] mb-1.5">Workspace name</label>
                  <input
                    type="text"
                    value={orgName}
                    onChange={(e) => setOrgName(e.target.value)}
                    placeholder="Acme Health"
                    className="w-full px-3 py-2 text-[14px] border border-[#e5e7eb] rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                  {orgName && (
                    <p className="text-[11px] text-[#9ca3af] mt-1 font-mono">slug: {slugify(orgName)}</p>
                  )}
                </div>

                <div>
                  <label className="block text-[12px] font-medium text-[#374151] mb-2">Primary compliance framework</label>
                  <div className="grid grid-cols-2 gap-2">
                    {FRAMEWORKS.map((f) => (
                      <button
                        key={f.value}
                        onClick={() => setFramework(f.value)}
                        className={cn(
                          "text-left p-3 rounded-lg border text-[13px] transition-colors",
                          framework === f.value
                            ? "border-indigo-500 bg-indigo-50"
                            : "border-[#e5e7eb] hover:border-[#d1d5db]"
                        )}
                      >
                        <div className={cn("font-semibold mb-0.5", framework === f.value ? "text-indigo-700" : "text-[#0d0f12]")}>
                          {f.label}
                        </div>
                        <div className="text-[11px] text-[#9ca3af]">{f.desc}</div>
                      </button>
                    ))}
                  </div>
                </div>
              </div>

              {error && <p className="mt-4 text-[13px] text-red-600">{error}</p>}

              <button
                onClick={createWorkspace}
                disabled={!orgName.trim() || loading}
                className="mt-6 w-full flex items-center justify-center gap-2 px-4 py-2.5 bg-[#0d0f12] text-white text-[14px] font-medium rounded-lg hover:bg-[#1f2937] transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              >
                {loading ? <span className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" /> : <>Continue <ChevronRight className="w-4 h-4" /></>}
              </button>
            </div>
          )}

          {/* ── Step 2: KMS ── */}
          {step === 2 && (
            <div>
              <div className="flex items-center gap-3 mb-1">
                <div className="bg-indigo-50 p-2 rounded-lg"><KeyRound className="w-5 h-5 text-indigo-600" /></div>
                <h2 className="text-[18px] font-semibold text-[#0d0f12]">Encryption key setup</h2>
              </div>
              <p className="text-[13px] text-[#6b7280] mb-6">
                Masker uses envelope encryption. Your data encryption keys (DEKs) are wrapped by a key encryption key (KEK).
              </p>

              <div className="space-y-3">
                {/* Masker-managed KMS */}
                <button
                  onClick={() => setKmsProvider("masker")}
                  className={cn(
                    "w-full text-left p-4 rounded-lg border transition-colors",
                    kmsProvider === "masker" ? "border-indigo-500 bg-indigo-50" : "border-[#e5e7eb] hover:border-[#d1d5db]"
                  )}
                >
                  <div className="flex items-center justify-between mb-1">
                    <span className={cn("text-[14px] font-semibold", kmsProvider === "masker" ? "text-indigo-700" : "text-[#0d0f12]")}>
                      Masker-managed KMS
                    </span>
                    {kmsProvider === "masker" && <Check className="w-4 h-4 text-indigo-600" />}
                  </div>
                  <p className="text-[12px] text-[#6b7280]">
                    We provision and rotate your KEK automatically. Zero ops overhead. Recommended for getting started.
                  </p>
                  <div className="mt-2 flex gap-2">
                    {["AES-256-GCM", "Auto-rotation", "FIPS 140-2"].map((t) => (
                      <span key={t} className="text-[10px] font-medium px-1.5 py-0.5 rounded bg-indigo-100 text-indigo-700">{t}</span>
                    ))}
                  </div>
                </button>

                {/* BYOK — greyed out */}
                <div className="relative">
                  <div className="w-full text-left p-4 rounded-lg border border-[#e5e7eb] opacity-50 cursor-not-allowed select-none">
                    <div className="flex items-center justify-between mb-1">
                      <span className="text-[14px] font-semibold text-[#0d0f12] flex items-center gap-2">
                        <Lock className="w-3.5 h-3.5" /> Bring Your Own KMS
                      </span>
                      <span className="text-[10px] font-medium px-2 py-0.5 rounded-full bg-[#f3f4f6] text-[#9ca3af]">Enterprise</span>
                    </div>
                    <p className="text-[12px] text-[#9ca3af]">
                      Connect your own AWS KMS, GCP Cloud KMS, or HashiCorp Vault. Your keys never leave your infrastructure.
                    </p>
                    <div className="mt-2 flex gap-2">
                      {["AWS KMS", "GCP KMS", "Vault"].map((t) => (
                        <span key={t} className="text-[10px] font-medium px-1.5 py-0.5 rounded bg-[#f3f4f6] text-[#9ca3af]">{t}</span>
                      ))}
                    </div>
                  </div>
                  <div className="absolute inset-0 flex items-center justify-center">
                    <span className="text-[12px] font-medium text-[#6b7280] bg-white px-3 py-1 rounded-full border border-[#e5e7eb] shadow-sm">
                      Contact us to unlock
                    </span>
                  </div>
                </div>
              </div>

              {error && <p className="mt-4 text-[13px] text-red-600">{error}</p>}

              <button
                onClick={setupKms}
                disabled={loading}
                className="mt-6 w-full flex items-center justify-center gap-2 px-4 py-2.5 bg-[#0d0f12] text-white text-[14px] font-medium rounded-lg hover:bg-[#1f2937] transition-colors disabled:opacity-40"
              >
                {loading ? <span className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" /> : <>Provision key <ChevronRight className="w-4 h-4" /></>}
              </button>
            </div>
          )}

          {/* ── Step 3: API Key ── */}
          {step === 3 && (
            <div>
              <div className="flex items-center gap-3 mb-1">
                <div className="bg-indigo-50 p-2 rounded-lg"><Shield className="w-5 h-5 text-indigo-600" /></div>
                <h2 className="text-[18px] font-semibold text-[#0d0f12]">Create your first API key</h2>
              </div>
              <p className="text-[13px] text-[#6b7280] mb-6">
                This key authenticates your SDK. You can create more keys with different scopes later.
              </p>

              <div className="space-y-4">
                <div>
                  <label className="block text-[12px] font-medium text-[#374151] mb-1.5">Key label</label>
                  <input
                    type="text"
                    value={keyLabel}
                    onChange={(e) => setKeyLabel(e.target.value)}
                    placeholder="Production"
                    className="w-full px-3 py-2 text-[14px] border border-[#e5e7eb] rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                </div>

                <div>
                  <label className="block text-[12px] font-medium text-[#374151] mb-2">Permissions</label>
                  <div className="space-y-2">
                    {PERMISSIONS.map((p) => (
                      <label key={p.value} className="flex items-center gap-3 cursor-pointer">
                        <input
                          type="checkbox"
                          checked={permissions.includes(p.value)}
                          onChange={() => togglePermission(p.value)}
                          className="w-4 h-4 rounded border-[#d1d5db] text-indigo-600 focus:ring-indigo-500"
                        />
                        <span className="text-[13px] text-[#374151]">{p.label}</span>
                        <span className="text-[11px] font-mono text-[#9ca3af]">{p.value}</span>
                      </label>
                    ))}
                  </div>
                </div>
              </div>

              {error && <p className="mt-4 text-[13px] text-red-600">{error}</p>}

              <button
                onClick={createApiKey}
                disabled={!keyLabel.trim() || permissions.length === 0 || loading}
                className="mt-6 w-full flex items-center justify-center gap-2 px-4 py-2.5 bg-[#0d0f12] text-white text-[14px] font-medium rounded-lg hover:bg-[#1f2937] transition-colors disabled:opacity-40"
              >
                {loading ? <span className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" /> : <>Create key <ChevronRight className="w-4 h-4" /></>}
              </button>
            </div>
          )}

          {/* ── Step 4: Download SDK ── */}
          {step === 4 && createdKey && (
            <div>
              <div className="flex items-center gap-3 mb-1">
                <div className="bg-green-50 p-2 rounded-lg"><Download className="w-5 h-5 text-green-600" /></div>
                <h2 className="text-[18px] font-semibold text-[#0d0f12]">You&apos;re ready</h2>
              </div>
              <p className="text-[13px] text-[#6b7280] mb-6">
                Your workspace, KMS key, and API key are provisioned. Copy your key now — it won&apos;t be shown again.
              </p>

              {/* API key reveal */}
              <div className="bg-[#0d0f12] rounded-lg p-4 mb-6">
                <div className="flex items-center justify-between mb-1">
                  <span className="text-[11px] text-[#6b7280] font-medium uppercase tracking-wide">Your API Key</span>
                  <button
                    onClick={() => navigator.clipboard.writeText(createdKey.fullKey)}
                    className="text-[11px] text-[#9ca3af] hover:text-white transition-colors"
                  >
                    Copy
                  </button>
                </div>
                <code className="text-[13px] text-green-400 font-mono break-all">{createdKey.fullKey}</code>
              </div>

              {/* SDK downloads */}
              <div className="space-y-3 mb-6">
                <a
                  href={`/api/sdk/download?format=python&key=${encodeURIComponent(createdKey.fullKey)}&framework=${framework}&org=${encodeURIComponent(orgName)}`}
                  className="flex items-center justify-between p-4 rounded-lg border border-[#e5e7eb] hover:border-indigo-300 hover:bg-indigo-50 transition-colors group"
                >
                  <div className="flex items-center gap-3">
                    <span className="text-xl">🐍</span>
                    <div>
                      <div className="text-[13px] font-semibold text-[#0d0f12] group-hover:text-indigo-700">Python SDK</div>
                      <div className="text-[11px] text-[#9ca3af]">masker_config.py — pre-configured with your key and policy</div>
                    </div>
                  </div>
                  <Download className="w-4 h-4 text-[#9ca3af] group-hover:text-indigo-600" />
                </a>

                <a
                  href={`/api/sdk/download?format=json&key=${encodeURIComponent(createdKey.fullKey)}&framework=${framework}&org=${encodeURIComponent(orgName)}`}
                  className="flex items-center justify-between p-4 rounded-lg border border-[#e5e7eb] hover:border-indigo-300 hover:bg-indigo-50 transition-colors group"
                >
                  <div className="flex items-center gap-3">
                    <span className="text-xl">⚙️</span>
                    <div>
                      <div className="text-[13px] font-semibold text-[#0d0f12] group-hover:text-indigo-700">JSON Config</div>
                      <div className="text-[11px] text-[#9ca3af]">masker_config.json — drop into any project</div>
                    </div>
                  </div>
                  <Download className="w-4 h-4 text-[#9ca3af] group-hover:text-indigo-600" />
                </a>
              </div>

              <button
                onClick={() => router.push("/overview")}
                className="w-full flex items-center justify-center gap-2 px-4 py-2.5 bg-[#0d0f12] text-white text-[14px] font-medium rounded-lg hover:bg-[#1f2937] transition-colors"
              >
                Go to dashboard <ChevronRight className="w-4 h-4" />
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
