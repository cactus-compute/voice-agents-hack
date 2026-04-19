"use client";

import { useState, useEffect, useCallback } from "react";
import { useSearchParams } from "next/navigation";
import { StatusChip } from "@/components/ui/StatusChip";
import { cn } from "@/lib/utils";
import { X, Mic, MessageSquare, SearchX } from "lucide-react";

// Shape returned by /api/sessions (audit_logs table)
interface SessionRow {
  id: string;
  session_id: string;
  channel: string;
  use_case: string;
  policy_version: string;
  status: string;
  risk_level: string;
  entities_detected: number;
  duration: string;
  raw_hash: string;
  redacted_transcript: string;
  entity_spans: unknown[];
  created_at: string;
}

function TableSkeleton() {
  return (
    <>
      {Array.from({ length: 5 }).map((_, i) => (
        <tr key={i} className="border-b border-[#f9fafb]">
          {Array.from({ length: 8 }).map((__, j) => (
            <td key={j} className="px-4 py-3">
              <div className={`h-3 bg-gray-100 rounded animate-pulse ${j === 0 ? "w-28" : "w-16"}`} />
            </td>
          ))}
        </tr>
      ))}
    </>
  );
}

export function SessionsClient() {
  const searchParams = useSearchParams();
  const [sessions, setSessions] = useState<SessionRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState<SessionRow | null>(null);
  const [filter, setFilter] = useState(searchParams.get("q") ?? "");

  const fetchSessions = useCallback(async () => {
    setLoading(true);
    try {
      const params = new URLSearchParams();
      if (filter) params.set("q", filter);
      const res = await fetch(`/api/sessions?${params}`);
      if (!res.ok) throw new Error();
      setSessions(await res.json());
    } catch {
      setSessions([]);
    } finally {
      setLoading(false);
    }
  }, [filter]);

  useEffect(() => { fetchSessions(); }, [fetchSessions]);

  return (
    <div className="flex gap-4 h-[calc(100vh-220px)] min-h-[500px]">
      {/* Table */}
      <div className={cn("flex flex-col rounded-lg border border-[#e5e7eb] bg-white overflow-hidden transition-all", selected ? "flex-1" : "w-full")}>
        {/* Filter */}
        <div className="flex items-center gap-3 px-4 py-3 border-b border-[#e5e7eb]">
          <input
            className="flex-1 text-[13px] outline-none placeholder:text-[#9ca3af]"
            placeholder="Filter by session ID, use case, status…"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
          />
          <div className="flex gap-2">
            {["all", "flagged", "blocked", "masked"].map((f) => (
              <button
                key={f}
                onClick={() => setFilter(f === "all" ? "" : f)}
                className={cn(
                  "text-[11px] px-2.5 py-1 rounded-full border transition-colors capitalize",
                  (f === "all" && !filter) || filter === f
                    ? "bg-[#0d0f12] text-white border-[#0d0f12]"
                    : "border-[#e5e7eb] text-[#6b7280] hover:border-[#0d0f12]"
                )}
              >
                {f}
              </button>
            ))}
          </div>
        </div>

        <div className="overflow-y-auto flex-1">
          <table className="w-full text-[12px]">
            <thead className="sticky top-0 bg-[#fafafa] z-10">
              <tr className="text-[#9ca3af] border-b border-[#e5e7eb]">
                <th className="text-left px-4 py-2.5 font-medium">Session ID</th>
                <th className="text-left px-4 py-2.5 font-medium">Time</th>
                <th className="text-left px-4 py-2.5 font-medium">Channel</th>
                <th className="text-left px-4 py-2.5 font-medium">Use Case</th>
                <th className="text-left px-4 py-2.5 font-medium">Status</th>
                <th className="text-left px-4 py-2.5 font-medium">Entities</th>
                <th className="text-left px-4 py-2.5 font-medium">Risk</th>
                <th className="text-left px-4 py-2.5 font-medium">Duration</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <TableSkeleton />
              ) : sessions.length === 0 ? (
                <tr>
                  <td colSpan={8} className="px-4 py-16 text-center">
                    <div className="flex flex-col items-center gap-2">
                      <SearchX className="w-6 h-6 text-[#d1d5db]" />
                      <p className="text-[13px] font-medium text-[#6b7280]">
                        {filter ? "No sessions match your filters" : "No sessions yet — integrate the SDK to start seeing data"}
                      </p>
                      {filter && (
                        <button onClick={() => setFilter("")} className="text-[12px] text-indigo-600 hover:underline">
                          Clear filters
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              ) : (
                sessions.map((s) => (
                  <tr
                    key={s.id}
                    onClick={() => setSelected(s)}
                    className={cn(
                      "border-b border-[#f9fafb] cursor-pointer transition-colors",
                      selected?.id === s.id ? "bg-[#f9fafb]" : "hover:bg-[#fafafa]"
                    )}
                  >
                    <td className="px-4 py-3 font-mono text-[#0d0f12]">{s.session_id}</td>
                    <td className="px-4 py-3 text-[#6b7280]">
                      {new Date(s.created_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
                    </td>
                    <td className="px-4 py-3">
                      <span className="flex items-center gap-1 text-[#6b7280]">
                        {s.channel === "voice" ? <Mic className="w-3 h-3" /> : <MessageSquare className="w-3 h-3" />}
                        {s.channel}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-[#374151]">{s.use_case}</td>
                    <td className="px-4 py-3"><StatusChip status={s.status as "clean" | "masked" | "blocked" | "flagged"} /></td>
                    <td className="px-4 py-3 text-[#374151]">{s.entities_detected}</td>
                    <td className="px-4 py-3"><StatusChip status={s.risk_level as "low" | "medium" | "high" | "critical"} /></td>
                    <td className="px-4 py-3 text-[#6b7280]">{s.duration}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Detail drawer */}
      {selected && (
        <div className="w-[380px] shrink-0 flex flex-col rounded-lg border border-[#e5e7eb] bg-white overflow-hidden">
          <div className="flex items-center justify-between px-5 py-3.5 border-b border-[#e5e7eb]">
            <div>
              <div className="font-mono text-[12px] text-[#9ca3af]">{selected.session_id}</div>
              <div className="text-[13px] font-semibold text-[#0d0f12] mt-0.5">{selected.use_case}</div>
            </div>
            <button onClick={() => setSelected(null)} className="text-[#9ca3af] hover:text-[#0d0f12]">
              <X className="w-4 h-4" />
            </button>
          </div>
          <div className="flex-1 overflow-y-auto p-5 space-y-4">
            <div className="grid grid-cols-2 gap-3 text-[12px]">
              {[
                ["Status", selected.status],
                ["Risk", selected.risk_level],
                ["Channel", selected.channel],
                ["Duration", selected.duration],
                ["Policy", selected.policy_version],
                ["Entities", String(selected.entities_detected)],
              ].map(([label, value]) => (
                <div key={label}>
                  <div className="text-[11px] text-[#9ca3af] uppercase tracking-wide mb-0.5">{label}</div>
                  <div className="font-medium text-[#0d0f12]">{value}</div>
                </div>
              ))}
            </div>
            <div className="border-t border-[#f3f4f6] pt-4">
              <div className="text-[11px] text-[#9ca3af] uppercase tracking-wide mb-1.5">Redacted Transcript</div>
              <div className="text-[12px] text-[#374151] bg-[#f9fafb] rounded-md p-3 font-mono leading-relaxed border border-[#e5e7eb]">
                {selected.redacted_transcript || <span className="italic text-[#9ca3af]">No transcript</span>}
              </div>
            </div>
            <div className="border-t border-[#f3f4f6] pt-4">
              <div className="text-[11px] text-[#9ca3af] uppercase tracking-wide mb-1.5">Raw Hash</div>
              <div className="text-[11px] font-mono text-[#9ca3af] break-all">{selected.raw_hash}</div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
