import { NextRequest, NextResponse } from "next/server";
import { API_KEYS } from "@/lib/mock-data";
import type { ApiKey } from "@/lib/mock-data";

const store: ApiKey[] = [...API_KEYS];

export async function POST(
  _req: NextRequest,
  { params }: { params: { id: string } }
) {
  const idx = store.findIndex((k) => k.id === params.id);
  if (idx === -1) {
    return NextResponse.json({ error: "Key not found" }, { status: 404 });
  }
  const key = store[idx];
  const envTag = key.environment === "production" ? "live" : "test";
  store[idx] = {
    ...key,
    prefix: `msk_${envTag}_${Math.random().toString(36).slice(2, 6)}`,
  };
  return NextResponse.json(store[idx]);
}
