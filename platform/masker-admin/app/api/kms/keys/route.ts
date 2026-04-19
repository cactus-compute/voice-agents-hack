import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { randomBytes } from "crypto";
import type { KmsKey, Org } from "@/lib/supabase/types";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const q = (client: ReturnType<typeof createClient>, table: string) => (client as any).from(table);

export async function GET() {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { data: rawOrg } = await q(supabase, "orgs").select("id").eq("owner_id", user.id).maybeSingle();
  const org = rawOrg as Pick<Org, "id"> | null;
  if (!org) return NextResponse.json([]);

  const { data } = await q(supabase, "kms_keys").select("*").eq("org_id", org.id).order("created_at", { ascending: false });
  return NextResponse.json((data ?? []) as KmsKey[]);
}

export async function POST(req: NextRequest) {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { data: rawOrg } = await q(supabase, "orgs").select("id").eq("owner_id", user.id).maybeSingle();
  const org = rawOrg as Pick<Org, "id"> | null;
  if (!org) return NextResponse.json({ error: "Org not found" }, { status: 404 });

  const body = await req.json() as Partial<KmsKey>;
  const keyMaterial = randomBytes(32).toString("hex");

  const { data, error } = await q(supabase, "kms_keys")
    .insert({ ...body, org_id: org.id, key_material_hash: keyMaterial, status: "active" })
    .select()
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data as KmsKey, { status: 201 });
}
