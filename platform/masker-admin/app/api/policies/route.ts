import { NextRequest, NextResponse } from "next/server";
import { POLICIES } from "@/lib/mock-data";
import type { Policy } from "@/lib/mock-data";

const store: Policy[] = [...POLICIES];

export async function GET() {
  return NextResponse.json(store);
}

export async function POST(req: NextRequest) {
  const body = (await req.json()) as Omit<Policy, "id" | "updatedAt">;
  const newPolicy: Policy = {
    ...body,
    id: `pol-${Date.now()}`,
    updatedAt: new Date().toISOString().split("T")[0],
  };
  store.push(newPolicy);
  return NextResponse.json(newPolicy, { status: 201 });
}
