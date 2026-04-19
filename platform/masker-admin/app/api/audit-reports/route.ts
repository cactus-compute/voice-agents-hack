import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import type { Org } from "@/lib/supabase/types";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const q = (client: ReturnType<typeof createClient>, table: string) => (client as any).from(table);

export async function GET() {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { data: rawOrg } = await q(supabase, "orgs").select("id").eq("owner_id", user.id).maybeSingle();
  const org = rawOrg as Pick<Org, "id"> | null;
  if (!org) return NextResponse.json([]);

  const { data: rawLogs } = await q(supabase, "audit_logs")
    .select("use_case, status, created_at")
    .eq("org_id", org.id)
    .order("created_at", { ascending: false });

  const logs = rawLogs as { use_case: string; status: string; created_at: string }[] | null;
  if (!logs?.length) return NextResponse.json([]);

  const groups: Record<string, { count: number; latest: string }> = {};
  for (const log of logs) {
    if (!groups[log.use_case]) groups[log.use_case] = { count: 0, latest: log.created_at };
    groups[log.use_case].count++;
  }

  const reports = Object.entries(groups).map(([useCase, { count, latest }], i) => ({
    id: `rpt-${i}`,
    name: `${useCase} Audit`,
    useCase,
    dateRange: `Up to ${new Date(latest).toLocaleDateString()}`,
    generatedAt: latest,
    generatedBy: "system",
    status: "ready",
    sessionCount: count,
    formats: ["PDF", "JSON", "CSV"],
  }));

  return NextResponse.json(reports);
}
