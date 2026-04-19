import { NextRequest, NextResponse } from "next/server";
import { API_KEYS } from "@/lib/mock-data";
import type { ApiKey } from "@/lib/mock-data";

const store: ApiKey[] = [...API_KEYS];

export async function PATCH(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const idx = store.findIndex((k) => k.id === params.id);
  if (idx === -1) {
    return NextResponse.json({ error: "Key not found" }, { status: 404 });
  }
  const body = (await req.json()) as Partial<ApiKey>;
  store[idx] = { ...store[idx], ...body };
  return NextResponse.json(store[idx]);
}
