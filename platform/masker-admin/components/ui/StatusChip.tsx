import { cn } from "@/lib/utils";

type Variant = "clean" | "masked" | "blocked" | "flagged" | "active" | "draft" | "archived" | "rotating" | "disabled" | "revoked" | "ready" | "generating" | "scheduled" | "low" | "medium" | "high" | "critical";

const STYLES: Record<Variant, string> = {
  clean:      "bg-emerald-50 text-emerald-700 border-emerald-200",
  masked:     "bg-blue-50 text-blue-700 border-blue-200",
  blocked:    "bg-red-50 text-red-700 border-red-200",
  flagged:    "bg-amber-50 text-amber-700 border-amber-200",
  active:     "bg-emerald-50 text-emerald-700 border-emerald-200",
  draft:      "bg-gray-50 text-gray-600 border-gray-200",
  archived:   "bg-gray-50 text-gray-400 border-gray-200",
  rotating:   "bg-amber-50 text-amber-700 border-amber-200",
  disabled:   "bg-gray-50 text-gray-400 border-gray-200",
  revoked:    "bg-red-50 text-red-600 border-red-200",
  ready:      "bg-emerald-50 text-emerald-700 border-emerald-200",
  generating: "bg-blue-50 text-blue-700 border-blue-200",
  scheduled:  "bg-purple-50 text-purple-700 border-purple-200",
  low:        "bg-gray-50 text-gray-500 border-gray-200",
  medium:     "bg-amber-50 text-amber-700 border-amber-200",
  high:       "bg-orange-50 text-orange-700 border-orange-200",
  critical:   "bg-red-50 text-red-700 border-red-200",
};

export function StatusChip({ status }: { status: Variant }) {
  return (
    <span className={cn(
      "inline-flex items-center px-2 py-0.5 rounded text-[11px] font-medium border capitalize",
      STYLES[status]
    )}>
      {status}
    </span>
  );
}
