import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createHash, randomBytes } from "crypto";
import type { ApiKey } from "@/lib/supabase/types";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const q = (client: ReturnType<typeof createClient>, table: string) => (client as any).from(table);

export async function POST(_req: NextRequest, { params }: { params: { id: string } }) {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { data: rawKey } = await q(supabase, "api_keys").select("*").eq("id", params.id).single();
  const existing = rawKey as ApiKey | null;
  if (!existing) return NextResponse.json({ error: "Key not found" }, { status: 404 });

  const envTag = existing.environment === "production" ? "live" : "test";
  const suffix = randomBytes(4).toString("hex");
  const prefix = `msk_${envTag}_${suffix}`;
  const fullKey = `${prefix}_${randomBytes(16).toString("hex")}`;
  const keyHash = createHash("sha256").update(fullKey).digest("hex");

  const { data, error } = await q(supabase, "api_keys")
    .update({ prefix, key_hash: keyHash, status: "active" })
    .eq("id", params.id)
    .select()
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ...(data as ApiKey), full_key: fullKey });
}
