import { NextResponse } from "next/server";
import { KMS_KEYS } from "@/lib/mock-data";

export async function GET() {
  return NextResponse.json(KMS_KEYS);
}
