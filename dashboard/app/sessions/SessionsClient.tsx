"use client";

import { useState, useEffect, useCallback } from "react";
import { useSearchParams } from "next/navigation";
import type { Session } from "@/lib/mock-data";
import { StatusChip } from "@/components/ui/StatusChip";
import { cn } from "@/lib/utils";
import { X, Mic, MessageSquare, ChevronRight, SearchX } from "lucide-react";

const TABS = ["Summary", "Timeline", "Transcript Diff", "Entities", "Audit Trail"] as const;
type Tab = typeof TABS[number];

function formatTs(ts: string) {
  return new Date(ts).toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
}

function TableSkeleton() {
  return (
    <>
      {Array.from({ length: 5 }).map((_, i) => (
        <tr key={i} className="border-b border-[#f9fafb]">
          {Array.from({ length: 9 }).map((__, j) => (
            <td key={j} className="px-4 py-3">
              <div className={`h-3 bg-gray-100 rounded animate-pulse ${j === 0 ? "w-28" : j === 3 ? "w-32" : "w-16"}`} />
            </td>
          ))}
          <td className="px-4 py-3" />
        </tr>
      ))}
    </>
  );
}

export function SessionsClient() {
  const searchParams = useSearchParams();
  const [sessions, setSessions] = useState<Session[]>([]);
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState<Session | null>(null);
  const [tab, setTab] = useState<Tab>("Summary");
  const [filter, setFilter] = useState(searchParams.get("q") ?? "");

  // Sync filter when URL param changes (e.g. from topbar search)
  useEffect(() => {
    const q = searchParams.get("q");
    if (q) setFilter(q);
  }, [searchParams]);

  const fetchSessions = useCallback(async () => {
    setLoading(true);
    try {
      const params = new URLSearchParams();
      if (filter) params.set("q", filter);
      const res = await fetch(`/api/sessions?${params.toString()}`);
      if (!res.ok) throw new Error("Failed to fetch sessions");
      setSessions(await res.json());
    } catch {
      setSessions([]);
    } finally {
      setLoading(false);
    }
  }, [filter]);

  useEffect(() => {
    fetchSessions();
  }, [fetchSessions]);

  return (
    <div className="flex gap-4 h-[calc(100vh-220px)] min-h-[500px]">
      {/* Table */}
      <div className={cn("flex flex-col rounded-lg border border-[#e5e7eb] bg-white overflow-hidden transition-all", selected ? "flex-1" : "w-full")}>
        {/* Filter bar */}
        <div className="flex items-center gap-3 px-4 py-3 border-b border-[#e5e7eb]">
          <label htmlFor="session-filter" className="sr-only">Filter sessions</label>
          <input
            id="session-filter"
            className="flex-1 text-[13px] outline-none placeholder:text-[#9ca3af]"
            placeholder="Filter by session ID, use case, status, risk…"
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
                    : "border-[#e5e7eb] text-[#6b7280] hover:border-[#0d0f12] hover:text-[#0d0f12]"
                )}
              >
                {f}
              </button>
            ))}
          </div>
        </div>

        {/* Table */}
        <div className="overflow-y-auto flex-1">
          <table className="w-full text-[12px]">
            <thead className="sticky top-0 bg-[#fafafa] z-10">
              <tr className="text-[#9ca3af] border-b border-[#e5e7eb]">
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Session ID</th>
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Time</th>
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Channel</th>
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Use Case</th>
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Policy</th>
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Status</th>
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Entities</th>
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Risk</th>
                <th scope="col" className="text-left px-4 py-2.5 font-medium">Duration</th>
                <th scope="col" className="px-4 py-2.5" />
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <TableSkeleton />
              ) : sessions.length === 0 ? (
                <tr>
                  <td colSpan={10} className="px-4 py-16 text-center">
                    <div className="flex flex-col items-center gap-2">
                      <SearchX className="w-6 h-6 text-[#d1d5db]" aria-hidden="true" />
                      <p className="text-[13px] font-medium text-[#6b7280]">No sessions match your filters</p>
                      <button
                        onClick={() => setFilter("")}
                        className="text-[12px] text-[#9ca3af] hover:text-[#0d0f12] transition-colors underline underline-offset-2"
                      >
                        Clear filters
                      </button>
                    </div>
                  </td>
                </tr>
              ) : (
                sessions.map((s) => (
                  <tr
                    key={s.id}
                    onClick={() => { setSelected(s); setTab("Summary"); }}
                    onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && (setSelected(s), setTab("Summary"))}
                    tabIndex={0}
                    role="button"
                    aria-label={`Session ${s.id}, ${s.useCase}, ${s.riskLevel} risk`}
                    className={cn(
                      "border-b border-[#f9fafb] cursor-pointer transition-colors outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[#0d0f12]",
                      selected?.id === s.id ? "bg-[#f9fafb]" : "hover:bg-[#fafafa]"
                    )}
                  >
                    <td className="px-4 py-3 font-mono text-[#0d0f12]">{s.id}</td>
                    <td className="px-4 py-3 text-[#6b7280]">{formatTs(s.timestamp)}</td>
                    <td className="px-4 py-3">
                      {s.channel === "voice"
                        ? <span className="flex items-center gap-1 text-[#6b7280]"><Mic className="w-3 h-3" /> Voice</span>
                        : <span className="flex items-center gap-1 text-[#6b7280]"><MessageSquare className="w-3 h-3" /> Text</span>
                      }
                    </td>
                    <td className="px-4 py-3 text-[#374151]">{s.useCase}</td>
                    <td className="px-4 py-3 font-mono text-[#9ca3af]">{s.policyVersion}</td>
                    <td className="px-4 py-3"><StatusChip status={s.status} /></td>
                    <td className="px-4 py-3 text-[#374151]">{s.entitiesDetected}</td>
                    <td className="px-4 py-3"><StatusChip status={s.riskLevel} /></td>
                    <td className="px-4 py-3 text-[#6b7280]">{s.duration}</td>
                    <td className="px-4 py-3 text-[#9ca3af]">
                      <ChevronRight className="w-3.5 h-3.5" />
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Drawer */}
      {selected && (
        <div className="w-[420px] shrink-0 flex flex-col rounded-lg border border-[#e5e7eb] bg-white overflow-hidden">
          {/* Drawer header */}
          <div className="flex items-center justify-between px-5 py-3.5 border-b border-[#e5e7eb]">
            <div>
              <div className="font-mono text-[12px] text-[#9ca3af]">{selected.id}</div>
              <div className="text-[13px] font-semibold text-[#0d0f12] mt-0.5">{selected.useCase}</div>
            </div>
            <button
              aria-label="Close session detail"
              onClick={() => setSelected(null)}
              className="text-[#9ca3af] hover:text-[#0d0f12] transition-colors"
            >
              <X className="w-4 h-4" aria-hidden="true" />
            </button>
          </div>

          {/* Tabs */}
          <div className="flex border-b border-[#e5e7eb] px-4">
            {TABS.map((t) => (
              <button
                key={t}
                onClick={() => setTab(t)}
                className={cn(
                  "text-[12px] font-medium py-2.5 px-2 mr-1 border-b-2 transition-colors",
                  tab === t
                    ? "border-[#0d0f12] text-[#0d0f12]"
                    : "border-transparent text-[#9ca3af] hover:text-[#6b7280]"
                )}
              >
                {t}
              </button>
            ))}
          </div>

          {/* Tab content */}
          <div className="flex-1 overflow-y-auto p-5">
            {tab === "Summary" && <SummaryTab session={selected} />}
            {tab === "Timeline" && <TimelineTab session={selected} />}
            {tab === "Transcript Diff" && <TranscriptDiffTab session={selected} />}
            {tab === "Entities" && <EntitiesTab session={selected} />}
            {tab === "Audit Trail" && <AuditTrailTab session={selected} />}
          </div>
        </div>
      )}
    </div>
  );
}

function Row({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex flex-col gap-0.5">
      <div className="text-[11px] font-medium text-[#9ca3af] uppercase tracking-wide">{label}</div>
      <div className={cn("text-[12px] text-[#0d0f12]", mono && "font-mono")}>{value}</div>
    </div>
  );
}

function SummaryTab({ session: s }: { session: Session }) {
  return (
    <div className="flex flex-col gap-4">
      <div className="grid grid-cols-2 gap-3">
        <Row label="Status" value={s.status} />
        <Row label="Risk Level" value={s.riskLevel} />
        <Row label="Channel" value={s.channel} />
        <Row label="Duration" value={s.duration} />
        <Row label="Policy Version" value={s.policyVersion} mono />
        <Row label="Entities Detected" value={String(s.entitiesDetected)} />
      </div>
      <div className="border-t border-[#f3f4f6] pt-4">
        <Row label="Raw Input Hash" value={s.rawHash} mono />
      </div>
      <div className="border-t border-[#f3f4f6] pt-4">
        <div className="text-[11px] font-medium text-[#9ca3af] uppercase tracking-wide mb-1.5">Redacted Transcript</div>
        <div className="text-[12px] text-[#374151] bg-[#f9fafb] rounded-md p-3 font-mono leading-relaxed border border-[#e5e7eb]">
          {s.redactedTranscript}
        </div>
      </div>
    </div>
  );
}

function TimelineTab({ session: s }: { session: Session }) {
  const events = [
    { time: "00:00", label: "Session started", detail: `Channel: ${s.channel}` },
    { time: "00:01", label: "Policy loaded", detail: s.policyVersion },
    ...s.entitySpans.map((e) => ({
      time: e.timestamp,
      label: `Detected ${e.type}`,
      detail: `Action: ${e.action} → ${e.masked}`,
    })),
    { time: s.duration, label: "Session ended", detail: `${s.entitiesDetected} entities processed` },
  ];

  return (
    <div className="flex flex-col gap-0">
      {events.map((ev, i) => (
        <div key={i} className="flex gap-3">
          <div className="flex flex-col items-center">
            <div className="w-2 h-2 rounded-full bg-[#0d0f12] mt-1 shrink-0" />
            {i < events.length - 1 && <div className="w-px flex-1 bg-[#e5e7eb] my-1" />}
          </div>
          <div className="pb-4">
            <div className="flex items-center gap-2">
              <span className="font-mono text-[11px] text-[#9ca3af]">{ev.time}</span>
              <span className="text-[12px] font-medium text-[#0d0f12]">{ev.label}</span>
            </div>
            <div className="text-[11px] text-[#6b7280] mt-0.5">{ev.detail}</div>
          </div>
        </div>
      ))}
    </div>
  );
}

function TranscriptDiffTab({ session: s }: { session: Session }) {
  const sorted = [...s.entitySpans].sort((a, b) => a.start - b.start);

  const originalParts: { text: string; highlight: boolean }[] = [];
  let remaining = s.redactedTranscript;
  for (const span of sorted) {
    const idx = remaining.indexOf(span.masked);
    if (idx === -1) continue;
    if (idx > 0) originalParts.push({ text: remaining.slice(0, idx), highlight: false });
    originalParts.push({ text: span.value, highlight: true });
    remaining = remaining.slice(idx + span.masked.length);
  }
  if (remaining) originalParts.push({ text: remaining, highlight: false });

  const redactedParts = s.redactedTranscript
    .split(/(\[[A-Z_]+\])/)
    .map((part, i) => ({ text: part, highlight: /^\[[A-Z_]+\]$/.test(part), key: `r-${i}` }));

  return (
    <div className="flex flex-col gap-4">
      <div>
        <div className="text-[11px] font-medium text-[#9ca3af] uppercase tracking-wide mb-2">
          Original (before masking)
        </div>
        <div className="text-[12px] font-mono leading-relaxed bg-red-50 border border-red-100 rounded-md p-3">
          {originalParts.length > 0
            ? originalParts.map((p, i) =>
                p.highlight
                  ? <mark key={i} className="bg-red-200 text-red-800 rounded px-0.5 not-italic">{p.text}</mark>
                  : <span key={i}>{p.text}</span>
              )
            : <span className="text-[#9ca3af] italic">No original transcript available</span>
          }
        </div>
      </div>
      <div>
        <div className="text-[11px] font-medium text-[#9ca3af] uppercase tracking-wide mb-2">
          Redacted (sent to model)
        </div>
        <div className="text-[12px] font-mono leading-relaxed bg-emerald-50 border border-emerald-100 rounded-md p-3">
          {redactedParts.map((p) =>
            p.highlight
              ? <mark key={p.key} className="bg-emerald-200 text-emerald-800 rounded px-0.5 not-italic">{p.text}</mark>
              : <span key={p.key}>{p.text}</span>
          )}
        </div>
      </div>
    </div>
  );
}

function EntitiesTab({ session: s }: { session: Session }) {
  if (s.entitySpans.length === 0) {
    return <div className="text-[13px] text-[#9ca3af] italic">No entities detected in this session.</div>;
  }
  return (
    <div className="flex flex-col gap-2">
      {s.entitySpans.map((e, i) => (
        <div key={i} className="rounded-md border border-[#e5e7eb] p-3 flex flex-col gap-1.5">
          <div className="flex items-center justify-between">
            <span className="text-[11px] font-semibold text-[#0d0f12] uppercase tracking-wide">{e.type}</span>
            <div className="flex items-center gap-1.5">
              <span className="text-[10px] font-mono text-[#9ca3af]">{e.timestamp}</span>
              <span className="text-[10px] px-1.5 py-0.5 rounded bg-[#f3f4f6] text-[#6b7280] font-medium">{e.action}</span>
            </div>
          </div>
          <div className="flex items-center gap-2 text-[12px] font-mono">
            <span className="text-red-600 line-through">{e.value}</span>
            <span className="text-[#9ca3af]">→</span>
            <span className="text-emerald-700">{e.masked}</span>
          </div>
        </div>
      ))}
    </div>
  );
}

function AuditTrailTab({ session: s }: { session: Session }) {
  const events = [
    { actor: "system", action: "Session created", detail: `Policy ${s.policyVersion} loaded`, time: "00:00" },
    { actor: "masker", action: "Detection pass completed", detail: `${s.entitiesDetected} entities found`, time: "00:01" },
    ...s.entitySpans.map((e) => ({
      actor: "masker",
      action: `Applied ${e.action} to ${e.type}`,
      detail: `Token: ${e.masked}`,
      time: e.timestamp,
    })),
    { actor: "system", action: "Session closed", detail: `Hash: ${s.rawHash}`, time: s.duration },
  ];

  return (
    <div className="flex flex-col gap-2">
      {events.map((ev, i) => (
        <div key={i} className="flex gap-3 text-[12px] py-2 border-b border-[#f9fafb] last:border-0">
          <span className="font-mono text-[#9ca3af] w-10 shrink-0">{ev.time}</span>
          <div className="flex flex-col gap-0.5">
            <span className="font-medium text-[#0d0f12]">{ev.action}</span>
            <span className="text-[#6b7280] font-mono text-[11px]">{ev.detail}</span>
            <span className="text-[10px] text-[#9ca3af]">actor: {ev.actor}</span>
          </div>
        </div>
      ))}
    </div>
  );
}
