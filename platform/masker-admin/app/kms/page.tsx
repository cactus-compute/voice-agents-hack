"use client";

import { useState, useEffect } from "react";
import { PageShell } from "@/components/layout/PageShell";
import { StatusChip } from "@/components/ui/StatusChip";

import { RotateCcw, Ban, ArrowRight } from "lucide-react";
import { cn } from "@/lib/utils";
import type { KmsKey } from "@/lib/supabase/types";

function Skeleton() {
  return (
    <>
      {Array.from({ length: 2 }).map((_, i) => (
        <tr key={i} className="border-b border-[#f9fafb]">
          {Array.from({ length: 7 }).map((__, j) => (
            <td key={j} className="px-5 py-3.5">
              <div className={`h-3 bg-gray-100 rounded animate-pulse ${j === 0 ? "w-40" : "w-20"}`} />
            </td>
          ))}
        </tr>
      ))}
    </>
  );
}

export default function KmsPage() {
  const [keys, setKeys] = useState<KmsKey[]>([]);
  const [loading, setLoading] = useState(true);
  const [pending, setPending] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/kms/keys").then(r => r.json()).then(setKeys).finally(() => setLoading(false));
  }, []);

  async function rotate(id: string) {
    setPending(id);
    try {
      const res = await fetch(`/api/kms/keys/${id}/rotate`, { method: "POST" });
      const updated = await res.json();
      setKeys(prev => prev.map(k => k.id === id ? updated : k));
    } finally { setPending(null); }
  }

  async function disable(id: string) {
    setPending(id);
    try {
      const res = await fetch(`/api/kms/keys/${id}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ status: "disabled" }) });
      const updated = await res.json();
      setKeys(prev => prev.map(k => k.id === id ? updated : k));
    } finally { setPending(null); }
  }

  return (
    <PageShell title="Managed KMS">
      <div className="flex items-start justify-between mb-6">
        <div>
          <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12]">Managed KMS</h2>
          <p className="text-[13px] text-[#6b7280] mt-1">Encryption keys for tokenization and rehydration.</p>
        </div>
      </div>

      {/* Key hierarchy */}
      <div className="rounded-lg border border-[#e5e7eb] bg-[#fafafa] p-5 mb-6">
        <div className="text-[12px] font-semibold text-[#9ca3af] uppercase tracking-wide mb-4">Key Hierarchy</div>
        <div className="flex items-center gap-0 flex-wrap gap-y-3">
          {[
            { label: "Masker HSM Root",   sub: "Managed boundary",          dark: true  },
            { label: "Workspace KEK",     sub: "Your org key",              dark: false },
            { label: "Per-session DEKs",  sub: "Auto-generated per call",   dark: false },
            { label: "Token Vault",       sub: "Reversible token binding",  dark: false },
          ].map((node, i, arr) => (
            <div key={node.label} className="flex items-center gap-0">
              <div className={cn("rounded-lg px-4 py-3", node.dark ? "bg-[#0d0f12] text-white" : "bg-white border border-[#e5e7eb] text-[#0d0f12]")}>
                <div className="text-[12px] font-semibold">{node.label}</div>
                <div className={cn("text-[11px] mt-0.5 font-mono", node.dark ? "text-gray-400" : "text-[#9ca3af]")}>{node.sub}</div>
              </div>
              {i < arr.length - 1 && <ArrowRight className="w-4 h-4 text-[#d1d5db] mx-2 shrink-0" />}
            </div>
          ))}
        </div>
      </div>

      {/* BYOK — greyed out */}
      <div className="relative rounded-lg border border-dashed border-[#e5e7eb] p-5 mb-6 opacity-60 select-none">
        <div className="flex items-center justify-between">
          <div>
            <div className="text-[13px] font-semibold text-[#0d0f12]">Bring Your Own KMS</div>
            <div className="text-[12px] text-[#9ca3af] mt-0.5">Connect AWS KMS, GCP Cloud KMS, or HashiCorp Vault. Enterprise plan.</div>
          </div>
          <span className="text-[11px] font-medium px-2.5 py-1 rounded-full bg-[#f3f4f6] text-[#9ca3af]">Enterprise</span>
        </div>
      </div>

      {/* Keys table */}
      <div className="rounded-lg border border-[#e5e7eb] bg-white overflow-hidden">
        <table className="w-full text-[12px]">
          <thead className="bg-[#fafafa]">
            <tr className="text-[#9ca3af] border-b border-[#e5e7eb]">
              <th className="text-left px-5 py-3 font-medium">Alias</th>
              <th className="text-left px-5 py-3 font-medium">Scope</th>
              <th className="text-left px-5 py-3 font-medium">Region</th>
              <th className="text-left px-5 py-3 font-medium">Rotation</th>
              <th className="text-left px-5 py-3 font-medium">Last Rotated</th>
              <th className="text-left px-5 py-3 font-medium">Status</th>
              <th className="px-5 py-3 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? <Skeleton /> : keys.length === 0 ? (
              <tr><td colSpan={7} className="px-5 py-12 text-center text-[13px] text-[#9ca3af]">No KMS keys — complete onboarding to provision one</td></tr>
            ) : keys.map(k => (
              <tr key={k.id} className="border-b border-[#f9fafb] last:border-0 hover:bg-[#fafafa]">
                <td className="px-5 py-3.5 font-mono text-[#0d0f12]">{k.alias}</td>
                <td className="px-5 py-3.5 text-[#6b7280]">{k.scope}</td>
                <td className="px-5 py-3.5 font-mono text-[#9ca3af]">{k.region}</td>
                <td className="px-5 py-3.5 text-[#6b7280]">{k.rotation_cadence}</td>
                <td className="px-5 py-3.5 text-[#6b7280]">{new Date(k.last_rotated_at).toLocaleDateString()}</td>
                <td className="px-5 py-3.5"><StatusChip status={k.status} /></td>
                <td className="px-5 py-3.5">
                  <div className="flex items-center gap-1.5">
                    <button title="Rotate" disabled={k.status !== "active" || pending === k.id} onClick={() => rotate(k.id)}
                      className="p-1.5 rounded border border-[#e5e7eb] text-[#6b7280] hover:border-[#0d0f12] hover:text-[#0d0f12] disabled:opacity-30">
                      <RotateCcw className={cn("w-3 h-3", pending === k.id && "animate-spin")} />
                    </button>
                    <button title="Disable" disabled={k.status === "disabled" || pending === k.id} onClick={() => disable(k.id)}
                      className="p-1.5 rounded border border-[#e5e7eb] text-[#6b7280] hover:border-red-400 hover:text-red-600 disabled:opacity-30">
                      <Ban className="w-3 h-3" />
                    </button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </PageShell>
  );
}
