import { notFound } from "next/navigation";
import Link from "next/link";
import { PageShell } from "@/components/layout/PageShell";
import { StatusChip } from "@/components/ui/StatusChip";
import type { Session } from "@/lib/mock-data";
import { ArrowLeft } from "lucide-react";

const BASE = process.env.NEXT_PUBLIC_BASE_URL ?? "http://localhost:3000";

async function getSession(id: string): Promise<Session | null> {
  const res = await fetch(`${BASE}/api/sessions/${id}`, { cache: "no-store" });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error("Failed to fetch session");
  return res.json();
}

const ACTION_COLORS: Record<string, string> = {
  mask:     "bg-blue-50 text-blue-700",
  redact:   "bg-red-50 text-red-700",
  tokenize: "bg-purple-50 text-purple-700",
  allow:    "bg-emerald-50 text-emerald-700",
  block:    "bg-red-50 text-red-800",
};

export default async function SessionDetailPage({
  params,
}: {
  params: { id: string };
}) {
  const session = await getSession(params.id);
  if (!session) notFound();

  return (
    <PageShell title={`Session ${session.id}`}>
      <div className="mb-4">
        <Link
          href="/sessions"
          className="inline-flex items-center gap-1.5 text-[13px] text-[#6b7280] hover:text-[#0d0f12] transition-colors"
        >
          <ArrowLeft className="w-3.5 h-3.5" /> Back to Sessions
        </Link>
      </div>

      <div className="flex items-start justify-between mb-6">
        <div>
          <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12] font-mono">{session.id}</h2>
          <p className="text-[13px] text-[#6b7280] mt-1">
            {session.useCase} · {session.channel} · {session.policyVersion}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <StatusChip status={session.status} />
          <StatusChip status={session.riskLevel} />
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        {/* Metadata */}
        <div className="bg-white rounded-lg border border-[#e5e7eb] p-5">
          <h3 className="text-[13px] font-semibold text-[#0d0f12] mb-4">Metadata</h3>
          <dl className="space-y-2.5 text-[12px]">
            {[
              ["Timestamp", new Date(session.timestamp).toLocaleString()],
              ["Duration", session.duration],
              ["Channel", session.channel],
              ["Use Case", session.useCase],
              ["Policy", session.policyVersion],
              ["Entities Detected", String(session.entitiesDetected)],
            ].map(([label, value]) => (
              <div key={label} className="flex justify-between gap-2">
                <dt className="text-[#9ca3af]">{label}</dt>
                <dd className="text-[#0d0f12] font-medium text-right">{value}</dd>
              </div>
            ))}
          </dl>
          <div className="mt-4 pt-4 border-t border-[#f3f4f6]">
            <p className="text-[11px] text-[#9ca3af] font-mono break-all">{session.rawHash}</p>
          </div>
        </div>

        {/* Redacted Transcript + Entities */}
        <div className="lg:col-span-2 bg-white rounded-lg border border-[#e5e7eb] p-5">
          <h3 className="text-[13px] font-semibold text-[#0d0f12] mb-3">Redacted Transcript</h3>
          <p className="text-[12px] text-[#374151] bg-[#f9fafb] rounded-md p-3 leading-relaxed font-mono border border-[#e5e7eb] mb-5">
            {session.redactedTranscript}
          </p>

          {session.entitySpans.length > 0 && (
            <>
              <h3 className="text-[13px] font-semibold text-[#0d0f12] mb-3">
                Detected Entities ({session.entitySpans.length})
              </h3>
              <div className="overflow-x-auto">
                <table className="w-full text-[12px]">
                  <thead>
                    <tr className="border-b border-[#f3f4f6]">
                      <th className="text-left py-2 pr-4 text-[11px] font-medium text-[#9ca3af]">Type</th>
                      <th className="text-left py-2 pr-4 text-[11px] font-medium text-[#9ca3af]">Original</th>
                      <th className="text-left py-2 pr-4 text-[11px] font-medium text-[#9ca3af]">Masked</th>
                      <th className="text-left py-2 pr-4 text-[11px] font-medium text-[#9ca3af]">Action</th>
                      <th className="text-left py-2 text-[11px] font-medium text-[#9ca3af]">At</th>
                    </tr>
                  </thead>
                  <tbody>
                    {session.entitySpans.map((span, i) => (
                      <tr key={i} className="border-b border-[#f9fafb]">
                        <td className="py-2 pr-4 font-mono text-[11px] text-[#6b7280]">{span.type}</td>
                        <td className="py-2 pr-4 text-[#374151]">{span.value}</td>
                        <td className="py-2 pr-4 font-mono text-[11px] text-indigo-600">{span.masked}</td>
                        <td className="py-2 pr-4">
                          <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${ACTION_COLORS[span.action] ?? "bg-gray-100 text-gray-600"}`}>
                            {span.action}
                          </span>
                        </td>
                        <td className="py-2 text-[11px] text-[#9ca3af]">{span.timestamp}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </div>
      </div>
    </PageShell>
  );
}
