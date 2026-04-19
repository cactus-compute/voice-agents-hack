import { Suspense } from "react";
import { PageShell } from "@/components/layout/PageShell";
import { SessionsClient } from "./SessionsClient";

function SessionsSkeleton() {
  return (
    <div className="rounded-lg border border-[#e5e7eb] overflow-hidden">
      <div className="h-10 bg-[#fafafa] border-b border-[#e5e7eb]" />
      {Array.from({ length: 5 }).map((_, i) => (
        <div key={i} className="flex items-center gap-4 px-4 py-3.5 border-b border-[#f9fafb] last:border-0">
          <div className="h-3 w-28 bg-gray-100 rounded animate-pulse" />
          <div className="h-3 w-12 bg-gray-100 rounded animate-pulse" />
          <div className="h-3 w-10 bg-gray-100 rounded animate-pulse" />
          <div className="h-3 w-32 bg-gray-100 rounded animate-pulse" />
          <div className="h-3 w-24 bg-gray-100 rounded animate-pulse" />
          <div className="h-5 w-14 bg-gray-100 rounded animate-pulse ml-auto" />
        </div>
      ))}
    </div>
  );
}

export default function SessionsPage() {
  return (
    <PageShell title="Sessions">
      <div className="mb-5">
        <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12]">
          Every protected session, with a full audit trail
        </h2>
        <p className="text-[13px] text-[#6b7280] mt-1">
          Click any row to inspect the transcript diff, entity spans, and audit trail.
        </p>
      </div>
      <Suspense fallback={<SessionsSkeleton />}>
        <SessionsClient />
      </Suspense>
    </PageShell>
  );
}
