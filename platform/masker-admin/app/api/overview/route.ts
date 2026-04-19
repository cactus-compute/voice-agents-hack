import { NextResponse } from "next/server";
import {
  OVERVIEW_METRICS,
  SESSION_VOLUME,
  TOP_ENTITY_TYPES,
  RECENT_INCIDENTS,
} from "@/lib/mock-data";

export async function GET() {
  return NextResponse.json({
    metrics: OVERVIEW_METRICS,
    sessionVolume: SESSION_VOLUME,
    topEntityTypes: TOP_ENTITY_TYPES,
    recentIncidents: RECENT_INCIDENTS,
  });
}
