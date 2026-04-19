import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createHash, randomBytes } from "crypto";
import type { ApiKey, Org } from "@/lib/supabase/types";

// Supabase v2.103+ resolves .from() as `never` in strict mode with custom Database types.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const q = (client: ReturnType<typeof createClient>, table: string) => (client as any).from(table);

export async function GET() {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { data: rawOrg } = await q(supabase, "orgs").select("id").eq("owner_id", user.id).maybeSingle();
  const org = rawOrg as Pick<Org, "id"> | null;
  if (!org) return NextResponse.json([]);

  const { data } = await q(supabase, "api_keys").select("*").eq("org_id", org.id).order("created_at", { ascending: false });
  return NextResponse.json((data ?? []) as ApiKey[]);
}

export async function POST(req: NextRequest) {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await req.json() as { label: string; permissions: string[]; environment: string; org_id?: string };

  const { data: rawOrg } = await q(supabase, "orgs").select("id").eq("owner_id", user.id).maybeSingle();
  const org = rawOrg as Pick<Org, "id"> | null;
  const orgId = body.org_id ?? org?.id;
  if (!orgId) return NextResponse.json({ error: "No org found" }, { status: 400 });

  const envTag = body.environment === "production" ? "live" : "test";
  const suffix = randomBytes(4).toString("hex");
  const prefix = `msk_${envTag}_${suffix}`;
  const fullKey = `${prefix}_${randomBytes(16).toString("hex")}`;
  const keyHash = createHash("sha256").update(fullKey).digest("hex");

  const { data, error } = await q(supabase, "api_keys").insert({
    org_id: orgId,
    label: body.label,
    key_hash: keyHash,
    prefix,
    permissions: body.permissions,
    environment: body.environment,
    status: "active",
    last_used_at: null,
  }).select().single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ...(data as ApiKey), full_key: fullKey }, { status: 201 });
}
