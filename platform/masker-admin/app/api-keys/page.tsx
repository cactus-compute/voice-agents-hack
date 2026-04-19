"use client";

import { useState, useEffect } from "react";
import { PageShell } from "@/components/layout/PageShell";
import type { ApiKey } from "@/lib/mock-data";
import { StatusChip } from "@/components/ui/StatusChip";
import { Button } from "@/components/ui/Button";
import { Plus, RotateCcw, Trash2, Copy, Check } from "lucide-react";
import { cn } from "@/lib/utils";

const PERMISSION_LABELS: Record<string, string> = {
  "read:sessions":    "Read sessions",
  "write:events":     "Write session events",
  "generate:reports": "Generate reports",
  "manage:policies":  "Manage policies",
  "use:tokenization": "Use tokenization",
  "kms:admin":        "KMS admin",
};

function formatLastUsed(ts: string) {
  const d = new Date(ts);
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      onClick={() => { navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1500); }}
      className="text-[#9ca3af] hover:text-[#0d0f12] transition-colors"
    >
      {copied ? <Check className="w-3.5 h-3.5 text-emerald-500" /> : <Copy className="w-3.5 h-3.5" />}
    </button>
  );
}

function ApiKeysSkeleton() {
  return (
    <>
      {Array.from({ length: 4 }).map((_, i) => (
        <tr key={i} className="border-b border-[#f9fafb]">
          {Array.from({ length: 6 }).map((__, j) => (
            <td key={j} className="px-5 py-3.5">
              <div className={`h-3 bg-gray-100 rounded animate-pulse ${j === 0 ? "w-36" : "w-24"}`} />
            </td>
          ))}
          <td className="px-5 py-3.5" />
        </tr>
      ))}
    </>
  );
}

export default function ApiKeysPage() {
  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [loading, setLoading] = useState(true);
  const [pending, setPending] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/keys")
      .then((r) => r.json())
      .then(setKeys)
      .finally(() => setLoading(false));
  }, []);

  async function revoke(id: string) {
    setPending(id);
    try {
      const res = await fetch(`/api/keys/${id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status: "revoked" }),
      });
      if (!res.ok) throw new Error();
      const updated: ApiKey = await res.json();
      setKeys((prev) => prev.map((k) => (k.id === id ? updated : k)));
    } finally {
      setPending(null);
    }
  }

  async function rotate(id: string) {
    setPending(id);
    try {
      const res = await fetch(`/api/keys/${id}/rotate`, { method: "POST" });
      if (!res.ok) throw new Error();
      const updated: ApiKey = await res.json();
      setKeys((prev) => prev.map((k) => (k.id === id ? updated : k)));
    } finally {
      setPending(null);
    }
  }

  return (
    <PageShell title="API Keys">
      <div className="flex items-start justify-between mb-6">
        <div>
          <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12]">API Keys</h2>
          <p className="text-[13px] text-[#6b7280] mt-1">Issue credentials for SDKs and services. Scope by environment and endpoint.</p>
        </div>
        <Button variant="primary">
          <Plus className="w-3.5 h-3.5" /> Create API Key
        </Button>
      </div>

      <div className="rounded-lg border border-[#e5e7eb] bg-white overflow-hidden">
        <table className="w-full text-[12px]">
          <thead className="bg-[#fafafa]">
            <tr className="text-[#9ca3af] border-b border-[#e5e7eb]">
              <th className="text-left px-5 py-3 font-medium">Label</th>
              <th className="text-left px-5 py-3 font-medium">Key Prefix</th>
              <th className="text-left px-5 py-3 font-medium">Permissions</th>
              <th className="text-left px-5 py-3 font-medium">Environment</th>
              <th className="text-left px-5 py-3 font-medium">Last Used</th>
              <th className="text-left px-5 py-3 font-medium">Status</th>
              <th className="px-5 py-3 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <ApiKeysSkeleton />
            ) : (
              keys.map((k) => (
                <tr key={k.id} className={cn("border-b border-[#f9fafb] last:border-0 hover:bg-[#fafafa] transition-colors", k.status === "revoked" && "opacity-60")}>
                  <td className="px-5 py-3.5 font-medium text-[#0d0f12]">{k.label}</td>
                  <td className="px-5 py-3.5">
                    <div className="flex items-center gap-1.5">
                      <span className="font-mono text-[#374151]">{k.prefix}••••</span>
                      <CopyButton text={k.prefix} />
                    </div>
                  </td>
                  <td className="px-5 py-3.5">
                    <div className="flex flex-wrap gap-1">
                      {k.permissions.map((p) => (
                        <span key={p} className="px-1.5 py-0.5 rounded bg-[#f3f4f6] text-[#6b7280] text-[10px] font-medium">
                          {PERMISSION_LABELS[p] ?? p}
                        </span>
                      ))}
                    </div>
                  </td>
                  <td className="px-5 py-3.5">
                    <span className={`text-[11px] font-medium ${
                      k.environment === "Production" || k.environment === "production" ? "text-emerald-700" :
                      k.environment === "Staging" || k.environment === "staging" ? "text-amber-700" : "text-[#6b7280]"
                    }`}>
                      {k.environment}
                    </span>
                  </td>
                  <td className="px-5 py-3.5 text-[#6b7280]">{formatLastUsed(k.lastUsed)}</td>
                  <td className="px-5 py-3.5"><StatusChip status={k.status} /></td>
                  <td className="px-5 py-3.5">
                    {k.status === "active" && (
                      <div className="flex items-center gap-1.5">
                        <button
                          title="Rotate"
                          disabled={pending === k.id}
                          onClick={() => rotate(k.id)}
                          className="p-1.5 rounded border border-[#e5e7eb] text-[#6b7280] hover:border-[#0d0f12] hover:text-[#0d0f12] transition-colors disabled:opacity-30"
                        >
                          <RotateCcw className={cn("w-3 h-3", pending === k.id && "animate-spin")} />
                        </button>
                        <button
                          title="Revoke"
                          disabled={pending === k.id}
                          onClick={() => revoke(k.id)}
                          className="p-1.5 rounded border border-[#e5e7eb] text-[#6b7280] hover:border-red-400 hover:text-red-600 transition-colors disabled:opacity-30"
                        >
                          <Trash2 className="w-3 h-3" />
                        </button>
                      </div>
                    )}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Permissions reference */}
      <div className="mt-6 rounded-lg border border-[#e5e7eb] bg-[#fafafa] p-5">
        <div className="text-[12px] font-semibold text-[#9ca3af] uppercase tracking-wide mb-3">Available Permissions</div>
        <div className="grid grid-cols-3 gap-2">
          {Object.entries(PERMISSION_LABELS).map(([key, label]) => (
            <div key={key} className="flex flex-col gap-0.5">
              <div className="text-[12px] font-medium text-[#0d0f12]">{label}</div>
              <div className="text-[11px] font-mono text-[#9ca3af]">{key}</div>
            </div>
          ))}
        </div>
      </div>
    </PageShell>
  );
}
