import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import type { Org } from "@/lib/supabase/types";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const q = (client: ReturnType<typeof createClient>, table: string) => (client as any).from(table);

export async function GET(req: NextRequest) {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { data: rawOrg } = await q(supabase, "orgs").select("id").eq("owner_id", user.id).maybeSingle();
  const org = rawOrg as Pick<Org, "id"> | null;
  if (!org) return NextResponse.json([]);

  const { searchParams } = req.nextUrl;
  const status = searchParams.get("status");
  const risk = searchParams.get("risk");
  const channel = searchParams.get("channel");
  const sq = searchParams.get("q");
  const limit = parseInt(searchParams.get("limit") ?? "100", 10);

  let query = q(supabase, "audit_logs")
    .select("*")
    .eq("org_id", org.id)
    .order("created_at", { ascending: false })
    .limit(limit);

  if (status) query = query.eq("status", status);
  if (risk) query = query.eq("risk_level", risk);
  if (channel) query = query.eq("channel", channel);
  if (sq) query = query.or(`use_case.ilike.%${sq}%,session_id.ilike.%${sq}%`);

  const { data } = await query;
  return NextResponse.json(data ?? []);
}
