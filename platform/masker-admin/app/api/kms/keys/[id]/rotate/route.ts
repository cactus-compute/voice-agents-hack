import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import type { KmsKey } from "@/lib/supabase/types";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const q = (client: ReturnType<typeof createClient>, table: string) => (client as any).from(table);

export async function POST(_req: NextRequest, { params }: { params: { id: string } }) {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { data, error } = await q(supabase, "kms_keys")
    .update({ last_rotated_at: new Date().toISOString(), status: "active" })
    .eq("id", params.id)
    .select()
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data as KmsKey);
}
