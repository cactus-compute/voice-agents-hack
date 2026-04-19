"use client";

import { useState, useEffect } from "react";
import { PageShell } from "@/components/layout/PageShell";
import { StatusChip } from "@/components/ui/StatusChip";
import { Button } from "@/components/ui/Button";
import { Plus, RotateCcw, Trash2, Copy, Check } from "lucide-react";
import { cn } from "@/lib/utils";
import type { ApiKey } from "@/lib/supabase/types";

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button onClick={() => { navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1500); }}
      className="text-[#9ca3af] hover:text-[#0d0f12] transition-colors">
      {copied ? <Check className="w-3.5 h-3.5 text-emerald-500" /> : <Copy className="w-3.5 h-3.5" />}
    </button>
  );
}

function Skeleton() {
  return (
    <>
      {Array.from({ length: 3 }).map((_, i) => (
        <tr key={i} className="border-b border-[#f9fafb]">
          {Array.from({ length: 6 }).map((__, j) => (
            <td key={j} className="px-5 py-3.5">
              <div className={`h-3 bg-gray-100 rounded animate-pulse ${j === 0 ? "w-36" : "w-20"}`} />
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
  const [showCreate, setShowCreate] = useState(false);
  const [newLabel, setNewLabel] = useState("");
  const [creating, setCreating] = useState(false);
  const [newKeyValue, setNewKeyValue] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/keys").then(r => r.json()).then(setKeys).finally(() => setLoading(false));
  }, []);

  async function revoke(id: string) {
    setPending(id);
    try {
      const res = await fetch(`/api/keys/${id}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ status: "revoked" }) });
      const updated = await res.json();
      setKeys(prev => prev.map(k => k.id === id ? updated : k));
    } finally { setPending(null); }
  }

  async function rotate(id: string) {
    setPending(id);
    try {
      const res = await fetch(`/api/keys/${id}/rotate`, { method: "POST" });
      const updated = await res.json();
      if (updated.full_key) setNewKeyValue(updated.full_key);
      setKeys(prev => prev.map(k => k.id === id ? updated : k));
    } finally { setPending(null); }
  }

  async function createKey() {
    if (!newLabel.trim()) return;
    setCreating(true);
    try {
      const res = await fetch("/api/keys", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ label: newLabel, permissions: ["sessions:read", "sessions:write", "audit:read"], environment: "production" }) });
      const created = await res.json();
      if (created.full_key) setNewKeyValue(created.full_key);
      setKeys(prev => [created, ...prev]);
      setNewLabel("");
      setShowCreate(false);
    } finally { setCreating(false); }
  }

  return (
    <PageShell title="API Keys">
      <div className="flex items-start justify-between mb-6">
        <div>
          <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12]">API Keys</h2>
          <p className="text-[13px] text-[#6b7280] mt-1">Authenticate your SDK and integrations.</p>
        </div>
        <Button variant="primary" onClick={() => setShowCreate(true)}><Plus className="w-3.5 h-3.5" /> Create Key</Button>
      </div>

      {/* New key reveal */}
      {newKeyValue && (
        <div className="bg-[#0d0f12] rounded-lg p-4 mb-5">
          <div className="flex items-center justify-between mb-1">
            <span className="text-[11px] text-[#6b7280] uppercase tracking-wide">New API Key — copy now, won&apos;t be shown again</span>
            <button onClick={() => setNewKeyValue(null)} className="text-[#6b7280] hover:text-white text-[11px]">Dismiss</button>
          </div>
          <div className="flex items-center gap-3">
            <code className="text-[13px] text-green-400 font-mono flex-1 break-all">{newKeyValue}</code>
            <CopyButton text={newKeyValue} />
          </div>
        </div>
      )}

      {/* Create form */}
      {showCreate && (
        <div className="bg-white rounded-lg border border-indigo-200 p-5 mb-5 flex gap-3 items-end">
          <div className="flex-1">
            <label className="block text-[12px] font-medium text-[#374151] mb-1.5">Label</label>
            <input type="text" value={newLabel} onChange={e => setNewLabel(e.target.value)} placeholder="e.g. Production Voice Agent"
              className="w-full px-3 py-1.5 text-sm border border-[#e5e7eb] rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500" />
          </div>
          <Button variant="primary" size="sm" onClick={createKey} disabled={creating}>{creating ? "Creating…" : "Create"}</Button>
          <Button variant="ghost" size="sm" onClick={() => setShowCreate(false)}>Cancel</Button>
        </div>
      )}

      <div className="rounded-lg border border-[#e5e7eb] bg-white overflow-hidden">
        <table className="w-full text-[12px]">
          <thead className="bg-[#fafafa]">
            <tr className="text-[#9ca3af] border-b border-[#e5e7eb]">
              <th className="text-left px-5 py-3 font-medium">Label</th>
              <th className="text-left px-5 py-3 font-medium">Prefix</th>
              <th className="text-left px-5 py-3 font-medium">Permissions</th>
              <th className="text-left px-5 py-3 font-medium">Environment</th>
              <th className="text-left px-5 py-3 font-medium">Last Used</th>
              <th className="text-left px-5 py-3 font-medium">Status</th>
              <th className="px-5 py-3" />
            </tr>
          </thead>
          <tbody>
            {loading ? <Skeleton /> : keys.length === 0 ? (
              <tr><td colSpan={7} className="px-5 py-12 text-center text-[13px] text-[#9ca3af]">No API keys yet — create one to get started</td></tr>
            ) : keys.map(k => (
              <tr key={k.id} className={cn("border-b border-[#f9fafb] last:border-0 hover:bg-[#fafafa]", k.status === "revoked" && "opacity-60")}>
                <td className="px-5 py-3.5 font-medium text-[#0d0f12]">{k.label}</td>
                <td className="px-5 py-3.5">
                  <div className="flex items-center gap-1.5">
                    <span className="font-mono text-[#374151]">{k.prefix}••••</span>
                    <CopyButton text={k.prefix} />
                  </div>
                </td>
                <td className="px-5 py-3.5">
                  <div className="flex flex-wrap gap-1">
                    {k.permissions.map(p => <span key={p} className="px-1.5 py-0.5 rounded bg-[#f3f4f6] text-[#6b7280] text-[10px]">{p}</span>)}
                  </div>
                </td>
                <td className="px-5 py-3.5 text-[#6b7280]">{k.environment}</td>
                <td className="px-5 py-3.5 text-[#6b7280]">{k.last_used_at ? new Date(k.last_used_at).toLocaleDateString() : "Never"}</td>
                <td className="px-5 py-3.5"><StatusChip status={k.status} /></td>
                <td className="px-5 py-3.5">
                  {k.status === "active" && (
                    <div className="flex items-center gap-1.5">
                      <button title="Rotate" disabled={pending === k.id} onClick={() => rotate(k.id)}
                        className="p-1.5 rounded border border-[#e5e7eb] text-[#6b7280] hover:border-[#0d0f12] hover:text-[#0d0f12] disabled:opacity-30">
                        <RotateCcw className={cn("w-3 h-3", pending === k.id && "animate-spin")} />
                      </button>
                      <button title="Revoke" disabled={pending === k.id} onClick={() => revoke(k.id)}
                        className="p-1.5 rounded border border-[#e5e7eb] text-[#6b7280] hover:border-red-400 hover:text-red-600 disabled:opacity-30">
                        <Trash2 className="w-3 h-3" />
                      </button>
                    </div>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </PageShell>
  );
}
