import { PageShell } from "@/components/layout/PageShell";
import { MetricCard } from "@/components/ui/MetricCard";
import { StatusChip } from "@/components/ui/StatusChip";
import { Button } from "@/components/ui/Button";
import {
  OVERVIEW_METRICS,
  SESSION_VOLUME,
  TOP_ENTITY_TYPES,
  RECENT_INCIDENTS,
  AUDIT_REPORTS,
} from "@/lib/mock-data";
import { ArrowRight, Download, Plus, Upload } from "lucide-react";
import Link from "next/link";

// Recharts must be client-rendered
import { OverviewCharts } from "./OverviewCharts";

export default function OverviewPage() {
  const m = OVERVIEW_METRICS;

  return (
    <PageShell title="Overview">
      {/* Headline */}
      <div className="mb-6">
        <h2 className="text-[22px] font-semibold tracking-tight text-[#0d0f12]">
          Compliance that feels operational, not bureaucratic
        </h2>
        <p className="text-[13px] text-[#6b7280] mt-1">
          {new Date().toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })} · Production · Acme Health
        </p>
      </div>

      {/* Metric cards */}
      <div className="grid grid-cols-3 xl:grid-cols-6 gap-3 mb-6">
        <MetricCard label="Active Policies" value={m.activePolicies} sub="across 3 frameworks" />
        <MetricCard label="Protected Sessions" value={m.protectedSessionsToday} sub="today" accent="green" />
        <MetricCard label="Entities Masked" value={m.entitiesMaskedToday} sub="today" />
        <MetricCard label="Failed Redactions" value={m.failedRedactions} sub="last 24h" accent={m.failedRedactions > 0 ? "red" : "green"} />
        <MetricCard label="Audit Readiness" value={`${m.auditReadinessScore}%`} sub="HIPAA baseline" accent="green" />
        <MetricCard label="KMS Health" value={m.kmsHealth} sub="all keys nominal" accent="green" />
      </div>

      {/* Charts + incidents row */}
      <div className="grid grid-cols-3 gap-4 mb-4">
        {/* Session volume */}
        <div className="col-span-2 rounded-lg border border-[#e5e7eb] bg-white p-5">
          <div className="flex items-center justify-between mb-4">
            <div>
              <div className="text-[13px] font-semibold text-[#0d0f12]">Session Volume</div>
              <div className="text-[12px] text-[#9ca3af]">Last 7 days</div>
            </div>
            <Link href="/sessions" className="text-[12px] text-[#6b7280] hover:text-[#0d0f12] flex items-center gap-1">
              View all <ArrowRight className="w-3 h-3" />
            </Link>
          </div>
          <OverviewCharts volumeData={SESSION_VOLUME} entityData={TOP_ENTITY_TYPES} />
        </div>

        {/* Recent incidents */}
        <div className="rounded-lg border border-[#e5e7eb] bg-white p-5">
          <div className="flex items-center justify-between mb-4">
            <div className="text-[13px] font-semibold text-[#0d0f12]">Recent Incidents</div>
            <Link href="/sessions" className="text-[12px] text-[#6b7280] hover:text-[#0d0f12] flex items-center gap-1">
              All <ArrowRight className="w-3 h-3" />
            </Link>
          </div>
          <div className="flex flex-col gap-3">
            {RECENT_INCIDENTS.map((inc) => (
              <div key={inc.id} className="flex flex-col gap-1 pb-3 border-b border-[#f3f4f6] last:border-0 last:pb-0">
                <div className="flex items-center justify-between">
                  <StatusChip status={inc.risk} />
                  <time className="text-[11px] text-[#9ca3af] font-mono">{inc.time}</time>
                </div>
                <p className="text-[12px] text-[#374151] leading-snug">{inc.summary}</p>
                <Link
                  href={`/sessions?q=${inc.id}`}
                  className="text-[11px] font-mono text-[#9ca3af] hover:text-[#0d0f12] transition-colors"
                  aria-label={`View session ${inc.id}`}
                >
                  {inc.id}
                </Link>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Recent reports + CTA */}
      <div className="grid grid-cols-3 gap-4">
        {/* Recent audit reports */}
        <div className="col-span-2 rounded-lg border border-[#e5e7eb] bg-white p-5">
          <div className="flex items-center justify-between mb-4">
            <div className="text-[13px] font-semibold text-[#0d0f12]">Recent Audit Reports</div>
            <Link href="/audit-reports" className="text-[12px] text-[#6b7280] hover:text-[#0d0f12] flex items-center gap-1">
              All reports <ArrowRight className="w-3 h-3" />
            </Link>
          </div>
          <table className="w-full text-[12px]">
            <thead>
              <tr className="text-[#9ca3af] border-b border-[#f3f4f6]">
                <th className="text-left pb-2 font-medium">Report</th>
                <th className="text-left pb-2 font-medium">Use Case</th>
                <th className="text-left pb-2 font-medium">Status</th>
                <th className="text-right pb-2 font-medium">Download</th>
              </tr>
            </thead>
            <tbody>
              {AUDIT_REPORTS.slice(0, 3).map((r) => (
                <tr key={r.id} className="border-b border-[#f9fafb] last:border-0">
                  <td className="py-2.5 text-[#0d0f12] font-medium">{r.name}</td>
                  <td className="py-2.5 text-[#6b7280]">{r.useCase}</td>
                  <td className="py-2.5"><StatusChip status={r.status} /></td>
                  <td className="py-2.5 text-right">
                    {r.status === "ready" && (
                      <Link href="/audit-reports" aria-label={`Download ${r.name}`} className="text-[#6b7280] hover:text-[#0d0f12] transition-colors inline-flex">
                        <Download className="w-3.5 h-3.5" aria-hidden="true" />
                      </Link>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* CTA strip */}
        <div className="rounded-lg border border-[#e5e7eb] bg-[#fafafa] p-5 flex flex-col gap-3">
          <div className="text-[13px] font-semibold text-[#0d0f12] mb-1">Quick Actions</div>
          <Link href="/copilot" className="w-full">
            <Button variant="primary" className="w-full justify-start gap-2">
              <Plus className="w-3.5 h-3.5" aria-hidden="true" /> Configure new use case
            </Button>
          </Link>
          <Link href="/sessions" className="w-full">
            <Button variant="secondary" className="w-full justify-start gap-2">
              <Upload className="w-3.5 h-3.5" aria-hidden="true" /> Test sample transcript
            </Button>
          </Link>
          <Link href="/audit-reports" className="w-full">
            <Button variant="secondary" className="w-full justify-start gap-2">
              <Download className="w-3.5 h-3.5" aria-hidden="true" /> Generate report
            </Button>
          </Link>
        </div>
      </div>
    </PageShell>
  );
}
