import { NextRequest, NextResponse } from "next/server";
import type { AuditReport } from "@/lib/mock-data";

export async function POST(req: NextRequest) {
  const body = (await req.json()) as {
    templateType: string;
    useCase: string;
    dateRange: { from: string; to: string };
  };

  const report: AuditReport = {
    id: `rpt-${Date.now()}`,
    name: `${body.templateType} – ${body.useCase}`,
    useCase: body.useCase,
    dateRange: `${body.dateRange.from} – ${body.dateRange.to}`,
    generatedAt: new Date().toISOString(),
    generatedBy: "api",
    status: "generating",
    sessionCount: 0,
    formats: ["PDF", "JSON", "CSV"],
  };

  return NextResponse.json(report, { status: 202 });
}
