import { NextRequest, NextResponse } from "next/server";
import { SESSIONS } from "@/lib/mock-data";

export async function GET(
  _req: NextRequest,
  { params }: { params: { id: string } }
) {
  const session = SESSIONS.find((s) => s.id === params.id);
  if (!session) {
    return NextResponse.json({ error: "Session not found" }, { status: 404 });
  }
  return NextResponse.json(session);
}
