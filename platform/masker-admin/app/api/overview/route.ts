import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import type { Org } from "@/lib/supabase/types";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const q = (client: ReturnType<typeof createClient>, table: string) => (client as any).from(table);

export async function GET() {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { data: rawOrg } = await q(supabase, "orgs").select("id, name, framework").eq("owner_id", user.id).maybeSingle();
  const org = rawOrg as Pick<Org, "id" | "name" | "framework"> | null;
  if (!org) return NextResponse.json({ error: "No org" }, { status: 404 });

  const today = new Date();
  today.setHours(0, 0, 0, 0);

  const [
    { count: totalToday },
    { data: entitiesData },
    { count: failedCount },
    { data: kmsKeys },
    { data: policies },
    { data: recentLogs },
    { data: volumeData },
  ] = await Promise.all([
    q(supabase, "audit_logs").select("*", { count: "exact", head: true })
      .eq("org_id", org.id).gte("created_at", today.toISOString()),
    q(supabase, "audit_logs").select("entities_detected")
      .eq("org_id", org.id).gte("created_at", today.toISOString()),
    q(supabase, "audit_logs").select("*", { count: "exact", head: true })
      .eq("org_id", org.id).eq("status", "blocked").gte("created_at", today.toISOString()),
    q(supabase, "kms_keys").select("status").eq("org_id", org.id),
    q(supabase, "api_keys").select("id").eq("org_id", org.id).eq("status", "active"),
    q(supabase, "audit_logs").select("session_id, status, risk_level, created_at, use_case")
      .eq("org_id", org.id).order("created_at", { ascending: false }).limit(5),
    q(supabase, "audit_logs").select("created_at")
      .eq("org_id", org.id)
      .gte("created_at", new Date(Date.now() - 7 * 86400000).toISOString()),
  ]);

  const entitiesMasked = (entitiesData ?? []).reduce(
    (sum: number, r: { entities_detected: number }) => sum + (r.entities_detected ?? 0), 0
  );
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
  const sessionVolume = Object.entries(buckets).map(([date, sessions]) => ({ date, sessions }));

  const recentIncidents = (recentLogs ?? [])
    .filter((r: { risk_level: string }) => r.risk_level === "high" || r.risk_level === "critical")
    .map((r: { session_id: string; risk_level: string; use_case: string; created_at: string }) => ({
      id: r.session_id,
      summary: `${r.risk_level} risk session — ${r.use_case}`,
      time: r.created_at,
      risk: r.risk_level,
    }));

  return NextResponse.json({
    metrics: {
      activePolicies: policies?.length ?? 0,
      protectedSessionsToday: totalToday ?? 0,
      entitiesMaskedToday: entitiesMasked,
      failedRedactions: failedCount ?? 0,
      auditReadinessScore: kmsHealthy ? 94 : 72,
      kmsHealth: kmsHealthy ? "Healthy" : "Degraded",
    },
    sessionVolume,
    topEntityTypes: [],
    recentIncidents,
  });
}
