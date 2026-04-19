import { NextRequest, NextResponse } from "next/server";
import { SESSIONS } from "@/lib/mock-data";
import type { Session, SessionStatus, RiskLevel, Channel } from "@/lib/mock-data";

export async function GET(req: NextRequest) {
  const { searchParams } = req.nextUrl;
  const status = searchParams.get("status") as SessionStatus | null;
  const risk = searchParams.get("risk") as RiskLevel | null;
  const channel = searchParams.get("channel") as Channel | null;
  const q = searchParams.get("q")?.toLowerCase() ?? null;
  const limitParam = searchParams.get("limit");
  const limit = limitParam ? parseInt(limitParam, 10) : null;

  let results: Session[] = SESSIONS;

  if (status) results = results.filter((s) => s.status === status);
  if (risk) results = results.filter((s) => s.riskLevel === risk);
  if (channel) results = results.filter((s) => s.channel === channel);
  if (q) {
    results = results.filter(
      (s) =>
        s.useCase.toLowerCase().includes(q) ||
        s.id.toLowerCase().includes(q) ||
        s.redactedTranscript.toLowerCase().includes(q) ||
        s.status.toLowerCase().includes(q) ||
        s.riskLevel.toLowerCase().includes(q)
    );
  }
  if (limit) results = results.slice(0, limit);

  return NextResponse.json(results);
}
