"use client";

import { useState, useEffect } from "react";
import { PageShell } from "@/components/layout/PageShell";
import type { Policy } from "@/lib/mock-data";
import { StatusChip } from "@/components/ui/StatusChip";
import { Button } from "@/components/ui/Button";
import { Plus, GitBranch, ChevronRight } from "lucide-react";
import { cn } from "@/lib/utils";

const ACTION_COLORS: Record<string, string> = {
  mask:     "bg-blue-50 text-blue-700 border-blue-200",
  redact:   "bg-red-50 text-red-700 border-red-200",
  tokenize: "bg-purple-50 text-purple-700 border-purple-200",
  allow:    "bg-emerald-50 text-emerald-700 border-emerald-200",
  block:    "bg-red-50 text-red-700 border-red-200",
};

function PolicySkeleton() {
  return (
    <>
      {Array.from({ length: 5 }).map((_, i) => (
        <tr key={i} className="border-b border-[#f9fafb]">
          {Array.from({ length: 6 }).map((__, j) => (
            <td key={j} className="px-5 py-3.5">
              <div className={`h-3 bg-gray-100 rounded animate-pulse ${j === 0 ? "w-32" : "w-20"}`} />
            </td>
          ))}
          <td className="px-5 py-3.5" />
        </tr>
      ))}
    </>
  );
}

export default function PoliciesPage() {
  const [policies, setPolicies] = useState<Policy[]>([]);
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState<Policy | null>(null);

  useEffect(() => {
    fetch("/api/policies")
      .then((r) => r.json())
      .then((data: Policy[]) => {
        setPolicies(data);
        setSelected(data[0] ?? null);
      })
      .finally(() => setLoading(false));
  }, []);

  return (
    <PageShell title="Policies">
      <div className="flex items-start justify-between mb-6">
        <div>
          <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12]">Compliance Policies</h2>
          <p className="text-[13px] text-[#6b7280] mt-1">Manage rules, versions, and entity-level actions.</p>
        </div>
        <Button variant="primary">
          <Plus className="w-3.5 h-3.5" aria-hidden="true" /> New Policy
        </Button>
      </div>

      <div className="flex gap-4 h-[calc(100vh-220px)] min-h-[500px]">
        {/* Policy list */}
        <div className="flex-1 rounded-lg border border-[#e5e7eb] bg-white overflow-hidden flex flex-col">
          <table className="w-full text-[12px]">
            <thead className="bg-[#fafafa] sticky top-0">
              <tr className="text-[#9ca3af] border-b border-[#e5e7eb]">
                <th scope="col" className="text-left px-5 py-3 font-medium">Name</th>
                <th scope="col" className="text-left px-5 py-3 font-medium">Framework</th>
                <th scope="col" className="text-left px-5 py-3 font-medium">Scope</th>
                <th scope="col" className="text-left px-5 py-3 font-medium">Version</th>
                <th scope="col" className="text-left px-5 py-3 font-medium">Status</th>
                <th scope="col" className="text-left px-5 py-3 font-medium">Last Updated</th>
                <th scope="col" className="px-5 py-3" />
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <PolicySkeleton />
              ) : (
                policies.map((p) => (
                  <tr
                    key={p.id}
                    onClick={() => setSelected(p)}
                    onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && setSelected(p)}
                    tabIndex={0}
                    role="button"
                    aria-pressed={selected?.id === p.id}
                    className={cn(
                      "border-b border-[#f9fafb] cursor-pointer transition-colors outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[#0d0f12]",
                      selected?.id === p.id ? "bg-[#f9fafb]" : "hover:bg-[#fafafa]"
                    )}
                  >
                    <td className="px-5 py-3.5 font-medium text-[#0d0f12]">{p.name}</td>
                    <td className="px-5 py-3.5">
                      <span className="px-2 py-0.5 rounded border border-[#e5e7eb] text-[#374151] text-[11px] font-medium">{p.framework}</span>
                    </td>
                    <td className="px-5 py-3.5 text-[#6b7280]">{p.scope}</td>
                    <td className="px-5 py-3.5 font-mono text-[#9ca3af]">v{p.version}</td>
                    <td className="px-5 py-3.5"><StatusChip status={p.status} /></td>
                    <td className="px-5 py-3.5 text-[#6b7280]">{p.updatedAt}</td>
                    <td className="px-5 py-3.5 text-[#9ca3af]">
                      <ChevronRight className="w-3.5 h-3.5" aria-hidden="true" />
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        {/* Detail panel */}
        {selected && (
          <div className="w-[360px] shrink-0 flex flex-col gap-3">
            <div className="rounded-lg border border-[#e5e7eb] bg-white p-5 flex-1 overflow-y-auto">
              <div className="flex items-center justify-between mb-4">
                <div>
                  <div className="text-[13px] font-semibold text-[#0d0f12]">{selected.name}</div>
                  <div className="text-[12px] text-[#9ca3af] mt-0.5 font-mono">
                    v{selected.version} · {selected.framework} · {selected.scope}
                  </div>
                </div>
                <StatusChip status={selected.status} />
              </div>

              <div className="flex flex-col gap-1 mb-5">
                {selected.rules.map((r) => (
                  <div key={r.entity} className="flex items-center justify-between py-2 border-b border-[#f9fafb] last:border-0">
                    <span className="font-mono text-[12px] text-[#374151]">{r.entity}</span>
                    <div className="flex items-center gap-1.5">
                      <span className={cn(
                        "px-1.5 py-0.5 rounded border text-[10px] font-medium",
                        ACTION_COLORS[r.action] ?? "bg-gray-50 text-gray-600 border-gray-200"
                      )}>
                        {r.action}
                      </span>
                      {r.rehydration && (
                        <span className="text-[10px] text-purple-600 font-medium">reversible</span>
                      )}
                    </div>
                  </div>
                ))}
              </div>

              <div className="text-[11px] text-[#9ca3af]">Last updated {selected.updatedAt}</div>
            </div>

            <div className="flex gap-2">
              <Button size="sm" variant="secondary" className="flex-1 justify-center">
                <GitBranch className="w-3.5 h-3.5" aria-hidden="true" /> Version History
              </Button>
              <Button size="sm" variant="secondary" className="flex-1 justify-center">
                Test Harness
              </Button>
            </div>
          </div>
        )}
      </div>
    </PageShell>
  );
}
