import { NextResponse } from "next/server";
import { AUDIT_REPORTS } from "@/lib/mock-data";

export async function GET() {
  return NextResponse.json(AUDIT_REPORTS);
}

export async function POST() {
  return NextResponse.json({ error: "Use /api/audit-reports/generate" }, { status: 400 });
}
