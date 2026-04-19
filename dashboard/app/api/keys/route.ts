import { NextRequest, NextResponse } from "next/server";
import { API_KEYS } from "@/lib/mock-data";
import type { ApiKey } from "@/lib/mock-data";

const store: ApiKey[] = [...API_KEYS];

export async function GET() {
  return NextResponse.json(store);
}

export async function POST(req: NextRequest) {
  const body = (await req.json()) as {
    label: string;
    permissions: string[];
    environment: string;
  };

  const prefix = `msk_${body.environment === "production" ? "live" : "test"}_${Math.random().toString(36).slice(2, 6)}`;

  const newKey: ApiKey = {
    id: `key-${Date.now()}`,
    label: body.label,
    prefix,
    permissions: body.permissions,
    environment: body.environment,
    lastUsed: new Date().toISOString(),
    status: "active",
    createdAt: new Date().toISOString(),
  };

  store.push(newKey);
  return NextResponse.json(newKey, { status: 201 });
}
