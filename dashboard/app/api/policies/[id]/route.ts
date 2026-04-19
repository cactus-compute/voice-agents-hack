import { NextRequest, NextResponse } from "next/server";
import { POLICIES } from "@/lib/mock-data";
import type { Policy } from "@/lib/mock-data";

const store: Policy[] = [...POLICIES];

export async function PATCH(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const idx = store.findIndex((p) => p.id === params.id);
  if (idx === -1) {
    return NextResponse.json({ error: "Policy not found" }, { status: 404 });
  }
  const body = (await req.json()) as Partial<Policy>;
  store[idx] = {
    ...store[idx],
    ...body,
    updatedAt: new Date().toISOString().split("T")[0],
  };
  return NextResponse.json(store[idx]);
}
