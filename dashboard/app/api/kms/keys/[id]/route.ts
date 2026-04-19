import { NextRequest, NextResponse } from "next/server";
import { KMS_KEYS } from "@/lib/mock-data";
import type { KmsKey } from "@/lib/mock-data";

const store: KmsKey[] = [...KMS_KEYS];

export async function PATCH(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const idx = store.findIndex((k) => k.id === params.id);
  if (idx === -1) {
    return NextResponse.json({ error: "Key not found" }, { status: 404 });
  }
  const body = (await req.json()) as Partial<KmsKey>;
  store[idx] = { ...store[idx], ...body };
  return NextResponse.json(store[idx]);
}
