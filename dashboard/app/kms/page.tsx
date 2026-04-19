"use client";

import { useState, useEffect } from "react";
import { PageShell } from "@/components/layout/PageShell";
import type { KmsKey } from "@/lib/mock-data";
import { StatusChip } from "@/components/ui/StatusChip";
import { Button } from "@/components/ui/Button";
import { Plus, RotateCcw, Ban, FileText, ArrowRight } from "lucide-react";
import { cn } from "@/lib/utils";

function KmsSkeleton() {
  return (
    <>
      {Array.from({ length: 4 }).map((_, i) => (
        <tr key={i} className="border-b border-[#f9fafb]">
          {Array.from({ length: 7 }).map((__, j) => (
            <td key={j} className="px-5 py-3.5">
              <div className={`h-3 bg-gray-100 rounded animate-pulse ${j === 0 ? "w-40" : "w-20"}`} />
            </td>
          ))}
          <td className="px-5 py-3.5" />
        </tr>
      ))}
    </>
  );
}

export default function KmsPage() {
  const [keys, setKeys] = useState<KmsKey[]>([]);
  const [loading, setLoading] = useState(true);
  const [pending, setPending] = useState<string | null>(null);
  const [accessLogKey, setAccessLogKey] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/kms/keys")
      .then((r) => r.json())
      .then(setKeys)
      .finally(() => setLoading(false));
  }, []);

  async function rotate(id: string) {
    setPending(id);
    try {
      const res = await fetch(`/api/kms/keys/${id}/rotate`, { method: "POST" });
      if (!res.ok) throw new Error();
      const updated: KmsKey = await res.json();
      setKeys((prev) => prev.map((k) => (k.id === id ? updated : k)));
    } finally {
      setPending(null);
    }
  }

  async function disable(id: string) {
    setPending(id);
    try {
      const res = await fetch(`/api/kms/keys/${id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status: "disabled" }),
      });
      if (!res.ok) throw new Error();
      const updated: KmsKey = await res.json();
      setKeys((prev) => prev.map((k) => (k.id === id ? updated : k)));
    } finally {
      setPending(null);
    }
  }

  return (
    <PageShell title="Managed KMS">
      <div className="flex items-start justify-between mb-6">
        <div>
          <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12]">
            Managed encryption keys for tokenization and rehydration
          </h2>
          <p className="text-[13px] text-[#6b7280] mt-1">Keys and secrets, without operational chaos.</p>
        </div>
        <Button variant="primary">
          <Plus className="w-3.5 h-3.5" aria-hidden="true" /> Create Key
        </Button>
      </div>

      {/* Key hierarchy */}
      <div className="rounded-lg border border-[#e5e7eb] bg-[#fafafa] p-5 mb-6">
        <div className="text-[12px] font-semibold text-[#9ca3af] uppercase tracking-wide mb-4">Key Hierarchy</div>
        <div className="flex items-center gap-0 flex-wrap gap-y-3">
          {[
            { label: "Masker HSM Root",   sub: "Managed boundary",           dark: true },
            { label: "Workspace KEK",     sub: "masker/workspace/acme",      dark: false },
            { label: "Per-use-case DEKs", sub: "healthcare · hr · finance",  dark: false },
            { label: "Token Vault",       sub: "Reversible token binding",   dark: false },
          ].map((node, i, arr) => (
            <div key={node.label} className="flex items-center gap-0">
              <div className={cn(
                "rounded-lg px-4 py-3",
                node.dark ? "bg-[#0d0f12] text-white" : "bg-white border border-[#e5e7eb] text-[#0d0f12]"
              )}>
                <div className="text-[12px] font-semibold">{node.label}</div>
                <div className={cn("text-[11px] mt-0.5 font-mono", node.dark ? "text-gray-400" : "text-[#9ca3af]")}>
                  {node.sub}
                </div>
              </div>
              {i < arr.length - 1 && (
                <ArrowRight className="w-4 h-4 text-[#d1d5db] mx-2 shrink-0" aria-hidden="true" />
              )}
            </div>
          ))}
        </div>
      </div>

      {/* KEK table */}
      <div className="rounded-lg border border-[#e5e7eb] bg-white overflow-hidden">
        <div className="px-5 py-3.5 border-b border-[#e5e7eb] text-[13px] font-semibold text-[#0d0f12]">
          Key Encryption Keys (KEKs)
        </div>
        <table className="w-full text-[12px]">
          <thead className="bg-[#fafafa]">
            <tr className="text-[#9ca3af] border-b border-[#e5e7eb]">
              <th scope="col" className="text-left px-5 py-3 font-medium">Key Alias</th>
              <th scope="col" className="text-left px-5 py-3 font-medium">Scope</th>
              <th scope="col" className="text-left px-5 py-3 font-medium">Region</th>
              <th scope="col" className="text-left px-5 py-3 font-medium">Created</th>
              <th scope="col" className="text-left px-5 py-3 font-medium">Rotation</th>
              <th scope="col" className="text-left px-5 py-3 font-medium">Last Rotated</th>
              <th scope="col" className="text-left px-5 py-3 font-medium">Status</th>
              <th scope="col" className="px-5 py-3 font-medium text-left">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <KmsSkeleton />
            ) : (
              keys.map((k) => (
                <tr key={k.id} className="border-b border-[#f9fafb] last:border-0 hover:bg-[#fafafa] transition-colors">
                  <td className="px-5 py-3.5 font-mono text-[#0d0f12]">{k.alias}</td>
                  <td className="px-5 py-3.5 text-[#6b7280]">{k.scope}</td>
                  <td className="px-5 py-3.5 font-mono text-[#9ca3af]">{k.region}</td>
                  <td className="px-5 py-3.5 text-[#6b7280]">{k.created}</td>
                  <td className="px-5 py-3.5 text-[#6b7280]">{k.rotationCadence}</td>
                  <td className="px-5 py-3.5 text-[#6b7280]">{k.lastRotated}</td>
                  <td className="px-5 py-3.5"><StatusChip status={k.status} /></td>
                  <td className="px-5 py-3.5">
                    <div className="flex items-center gap-1.5">
                      <button
                        aria-label={`Rotate key ${k.alias}`}
                        disabled={k.status === "disabled" || k.status === "rotating" || pending === k.id}
                        onClick={() => rotate(k.id)}
                        className="p-1.5 rounded border border-[#e5e7eb] text-[#6b7280] hover:border-[#0d0f12] hover:text-[#0d0f12] transition-colors disabled:opacity-30 disabled:cursor-not-allowed"
                      >
                        <RotateCcw className={cn("w-3 h-3", pending === k.id && "animate-spin")} aria-hidden="true" />
                      </button>
                      <button
                        aria-label={`Disable key ${k.alias}`}
                        disabled={k.status === "disabled" || pending === k.id}
                        onClick={() => disable(k.id)}
                        className="p-1.5 rounded border border-[#e5e7eb] text-[#6b7280] hover:border-red-400 hover:text-red-600 transition-colors disabled:opacity-30 disabled:cursor-not-allowed"
                      >
                        <Ban className="w-3 h-3" aria-hidden="true" />
                      </button>
                      <button
                        aria-label={`View access log for ${k.alias}`}
                        onClick={() => setAccessLogKey(accessLogKey === k.id ? null : k.id)}
                        className={cn(
                          "p-1.5 rounded border transition-colors",
                          accessLogKey === k.id
                            ? "border-[#0d0f12] text-[#0d0f12] bg-[#f9fafb]"
                            : "border-[#e5e7eb] text-[#6b7280] hover:border-[#0d0f12] hover:text-[#0d0f12]"
                        )}
                      >
                        <FileText className="w-3 h-3" aria-hidden="true" />
                      </button>
                    </div>
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>

        {/* Inline access log */}
        {accessLogKey && (
          <div className="border-t border-[#e5e7eb] px-5 py-4 bg-[#fafafa]">
            <div className="text-[12px] font-semibold text-[#0d0f12] mb-3">
              Access Log — {keys.find((k) => k.id === accessLogKey)?.alias}
            </div>
            <div className="flex flex-col gap-2 text-[11px] font-mono">
              {[
                { time: "2026-04-18 14:31:02", actor: "masker-sdk",    action: "encrypt",  result: "ok" },
                { time: "2026-04-18 14:28:55", actor: "masker-sdk",    action: "encrypt",  result: "ok" },
                { time: "2026-04-18 09:00:00", actor: "rotation-svc",  action: "rotate",   result: "ok" },
                { time: "2026-04-17 22:14:11", actor: "masker-sdk",    action: "decrypt",  result: "ok" },
                { time: "2026-04-17 18:03:44", actor: "audit-service", action: "describe", result: "ok" },
              ].map((ev, i) => (
                <div key={i} className="flex items-center gap-4 text-[#6b7280]">
                  <span className="text-[#9ca3af] w-36 shrink-0">{ev.time}</span>
                  <span className="w-28 shrink-0">{ev.actor}</span>
                  <span className="w-16 shrink-0">{ev.action}</span>
                  <span className="text-emerald-600 font-medium">{ev.result}</span>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </PageShell>
  );
}
