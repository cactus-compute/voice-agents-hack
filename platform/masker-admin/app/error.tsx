"use client";

import { useEffect } from "react";
import { AlertTriangle, RotateCcw } from "lucide-react";

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <div className="flex flex-col flex-1 items-center justify-center p-6 bg-white">
      <div className="flex flex-col items-center gap-4 max-w-sm text-center">
        <div className="w-10 h-10 rounded-full bg-red-50 flex items-center justify-center">
          <AlertTriangle className="w-5 h-5 text-red-500" aria-hidden="true" />
        </div>
        <div>
          <h2 className="text-[15px] font-semibold text-[#0d0f12] mb-1">Something went wrong</h2>
          <p className="text-[13px] text-[#6b7280] leading-relaxed">
            {error.message || "An unexpected error occurred. Try refreshing the page."}
          </p>
          {error.digest && (
            <p className="text-[11px] font-mono text-[#9ca3af] mt-2">Error ID: {error.digest}</p>
          )}
        </div>
        <button
          onClick={reset}
          className="flex items-center gap-2 px-4 py-2 rounded-md bg-[#0d0f12] text-white text-[13px] font-medium hover:bg-[#1f2937] transition-colors"
        >
          <RotateCcw className="w-3.5 h-3.5" aria-hidden="true" />
          Try again
        </button>
      </div>
    </div>
  );
}
