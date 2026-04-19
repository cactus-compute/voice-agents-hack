import { NextRequest, NextResponse } from "next/server";
import { AUDIT_REPORTS } from "@/lib/mock-data";

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const report = AUDIT_REPORTS.find((r) => r.id === params.id);
  if (!report) {
    return NextResponse.json({ error: "Report not found" }, { status: 404 });
  }

  const format = req.nextUrl.searchParams.get("format") ?? "PDF";

  return NextResponse.json({
    url: `/downloads/${params.id}.${format.toLowerCase()}`,
    format,
    reportName: report.name,
    expiresAt: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
  });
}
