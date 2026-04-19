import { PageShell } from "@/components/layout/PageShell";
import { MetricCard } from "@/components/ui/MetricCard";
import { StatusChip } from "@/components/ui/StatusChip";
import { Button } from "@/components/ui/Button";
import { ArrowRight, Download, Plus, Upload } from "lucide-react";
import Link from "next/link";
import { OverviewCharts } from "./OverviewCharts";
import { createClient } from "@/lib/supabase/server";

async function getOverview() {
  // Server-side: call our own API route via internal fetch
  // Use Supabase directly to avoid absolute URL requirement
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sb = supabase as any;
  const { data: rawOrg } = await sb.from("orgs").select("id, name, framework").eq("owner_id", user.id).maybeSingle();
  const org = rawOrg as { id: string; name: string; framework: string } | null;
  if (!org) return null;

  const today = new Date(); today.setHours(0, 0, 0, 0);

  const [
    { count: totalToday },
    { data: entitiesData },
    { count: failedCount },
    { data: kmsKeys },
    { data: apiKeys },
    { data: recentLogs },
    { data: volumeData },
  ] = await Promise.all([
    sb.from("audit_logs").select("*", { count: "exact", head: true }).eq("org_id", org.id).gte("created_at", today.toISOString()),
    sb.from("audit_logs").select("entities_detected").eq("org_id", org.id).gte("created_at", today.toISOString()),
    sb.from("audit_logs").select("*", { count: "exact", head: true }).eq("org_id", org.id).eq("status", "blocked").gte("created_at", today.toISOString()),
    sb.from("kms_keys").select("status").eq("org_id", org.id),
    sb.from("api_keys").select("id").eq("org_id", org.id).eq("status", "active"),
    sb.from("audit_logs").select("session_id, status, risk_level, created_at, use_case").eq("org_id", org.id).order("created_at", { ascending: false }).limit(5),
    sb.from("audit_logs").select("created_at").eq("org_id", org.id).gte("created_at", new Date(Date.now() - 7 * 86400000).toISOString()),
  ]);

  const entitiesMasked = (entitiesData ?? []).reduce((s: number, r: { entities_detected?: number }) => s + (r.entities_detected ?? 0), 0);
  const kmsHealthy = (kmsKeys ?? []).every((k: { status: string }) => k.status === "active");

  const buckets: Record<string, number> = {};
  for (let i = 6; i >= 0; i--) {
    const d = new Date(Date.now() - i * 86400000);
    buckets[d.toLocaleDateString("en-US", { month: "short", day: "numeric" })] = 0;
  }
  (volumeData ?? []).forEach((r: { created_at: string }) => {
    const label = new Date(r.created_at).toLocaleDateString("en-US", { month: "short", day: "numeric" });
    if (label in buckets) buckets[label]++;
  });

  return {
    org,
    metrics: {
      activePolicies: apiKeys?.length ?? 0,
      protectedSessionsToday: totalToday ?? 0,
      entitiesMaskedToday: entitiesMasked,
      failedRedactions: failedCount ?? 0,
      auditReadinessScore: kmsHealthy ? 94 : 72,
      kmsHealth: kmsHealthy ? "Healthy" : "Degraded",
    },
    sessionVolume: Object.entries(buckets).map(([date, sessions]) => ({ date, sessions })),
    topEntityTypes: [] as { type: string; count: number }[],
    recentIncidents: (recentLogs ?? [])
      .filter((r: { risk_level: string }) => r.risk_level === "high" || r.risk_level === "critical")
      .map((r: { session_id: string; risk_level: string; use_case: string; created_at: string }) => ({
        id: r.session_id,
        summary: `${r.risk_level} risk — ${r.use_case}`,
        time: r.created_at,
        risk: r.risk_level as "high" | "critical",
      })),
    recentReports: [] as { id: string; name: string; useCase: string; status: string }[],
  };
}

export default async function OverviewPage() {
  const data = await getOverview();

  // No org yet — prompt to complete onboarding
  if (!data) {
    return (
      <PageShell title="Overview">
        <div className="flex flex-col items-center justify-center h-[60vh] gap-4 text-center">
          <p className="text-[15px] font-medium text-[#0d0f12]">Finish setting up your workspace</p>
          <p className="text-[13px] text-[#6b7280]">Complete onboarding to see your compliance dashboard.</p>
          <Link href="/onboarding">
            <Button variant="primary">Complete setup</Button>
          </Link>
        </div>
      </PageShell>
    );
  }

  const { org, metrics: m, sessionVolume, topEntityTypes, recentReports } = data;
  const recentIncidents = data.recentIncidents as { id: string; summary: string; time: string; risk: "high" | "critical" }[];
  const hasData = m.protectedSessionsToday > 0;

  return (
    <PageShell title="Overview">
      <div className="mb-6">
        <h2 className="text-[22px] font-semibold tracking-tight text-[#0d0f12]">
          {org.name}
        </h2>
        <p className="text-[13px] text-[#6b7280] mt-1">
          {new Date().toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })} · Production · {org.framework}
        </p>
      </div>

      {/* Metric cards */}
      <div className="grid grid-cols-3 xl:grid-cols-6 gap-3 mb-6">
        <MetricCard label="Active API Keys"          value={m.activePolicies}            sub="in production" />
        <MetricCard label="Protected Sessions"       value={m.protectedSessionsToday}    sub="today" accent={hasData ? "green" : undefined} />
        <MetricCard label="Entities Masked"          value={m.entitiesMaskedToday}       sub="today" />
        <MetricCard label="Failed Redactions"        value={m.failedRedactions}          sub="last 24h" accent={m.failedRedactions > 0 ? "red" : "green"} />
        <MetricCard label="Audit Readiness"          value={`${m.auditReadinessScore}%`} sub={org.framework + " baseline"} accent="green" />
        <MetricCard label="KMS Health"               value={m.kmsHealth}                 sub="encryption keys" accent={m.kmsHealth === "Healthy" ? "green" : "red"} />
      </div>

      {!hasData ? (
        /* Empty state — new workspace */
        <div className="rounded-lg border border-dashed border-[#e5e7eb] bg-[#fafafa] p-12 text-center mb-6">
          <p className="text-[15px] font-medium text-[#0d0f12] mb-2">No sessions yet</p>
          <p className="text-[13px] text-[#6b7280] mb-6 max-w-sm mx-auto">
            Integrate the Masker SDK into your voice agent and sessions will appear here in real-time.
          </p>
          <div className="flex items-center justify-center gap-3">
            <Link href="/api-keys">
              <Button variant="primary"><Plus className="w-3.5 h-3.5" /> Get API key</Button>
            </Link>
            <a href="/api/sdk/download?format=python&key=YOUR_KEY&framework=HIPAA&org=My+Org">
              <Button variant="secondary"><Download className="w-3.5 h-3.5" /> Download SDK</Button>
            </a>
          </div>
        </div>
      ) : (
        <div className="grid grid-cols-3 gap-4 mb-4">
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
            <OverviewCharts volumeData={sessionVolume} entityData={topEntityTypes} />
          </div>

          <div className="rounded-lg border border-[#e5e7eb] bg-white p-5">
            <div className="flex items-center justify-between mb-4">
              <div className="text-[13px] font-semibold text-[#0d0f12]">Recent Incidents</div>
              <Link href="/sessions" className="text-[12px] text-[#6b7280] hover:text-[#0d0f12] flex items-center gap-1">
                All <ArrowRight className="w-3 h-3" />
              </Link>
            </div>
            {recentIncidents.length === 0 ? (
              <p className="text-[12px] text-[#9ca3af] italic">No incidents today</p>
            ) : (
              <div className="flex flex-col gap-3">
                {recentIncidents.map((inc) => (
                  <div key={inc.id} className="flex flex-col gap-1 pb-3 border-b border-[#f3f4f6] last:border-0 last:pb-0">
                    <div className="flex items-center justify-between">
                      <StatusChip status={inc.risk as "high" | "critical"} />
                      <time className="text-[11px] text-[#9ca3af] font-mono">
                        {new Date(inc.time).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
                      </time>
                    </div>
                    <p className="text-[12px] text-[#374151] leading-snug">{inc.summary}</p>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      {/* Quick actions */}
      <div className="grid grid-cols-3 gap-4">
        <div className="col-span-2 rounded-lg border border-[#e5e7eb] bg-white p-5">
          <div className="text-[13px] font-semibold text-[#0d0f12] mb-4">Recent Audit Reports</div>
          {recentReports.length === 0 ? (
            <p className="text-[12px] text-[#9ca3af] italic">
              Reports appear here once your SDK sends sessions.{" "}
              <Link href="/audit-reports" className="text-indigo-600 hover:underline">View all</Link>
            </p>
          ) : (
            <table className="w-full text-[12px]">
              <tbody>
                {recentReports.map((r) => (
                  <tr key={r.id} className="border-b border-[#f9fafb] last:border-0">
                    <td className="py-2.5 text-[#0d0f12] font-medium">{r.name}</td>
                    <td className="py-2.5 text-[#6b7280]">{r.useCase}</td>
                    <td className="py-2.5"><StatusChip status={r.status as "ready" | "generating" | "scheduled"} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        <div className="rounded-lg border border-[#e5e7eb] bg-[#fafafa] p-5 flex flex-col gap-3">
          <div className="text-[13px] font-semibold text-[#0d0f12] mb-1">Quick Actions</div>
          <Link href="/copilot" className="w-full">
            <Button variant="primary" className="w-full justify-start gap-2">
              <Plus className="w-3.5 h-3.5" /> Configure use case
            </Button>
          </Link>
          <Link href="/api-keys" className="w-full">
            <Button variant="secondary" className="w-full justify-start gap-2">
              <Upload className="w-3.5 h-3.5" /> Manage API keys
            </Button>
          </Link>
          <Link href="/audit-reports" className="w-full">
            <Button variant="secondary" className="w-full justify-start gap-2">
              <Download className="w-3.5 h-3.5" /> Generate report
            </Button>
          </Link>
        </div>
      </div>
    </PageShell>
  );
}
