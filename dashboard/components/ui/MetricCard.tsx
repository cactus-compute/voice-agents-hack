import { cn } from "@/lib/utils";

interface MetricCardProps {
  label: string;
  value: string | number;
  sub?: string;
  accent?: "default" | "amber" | "red" | "green";
}

const ACCENT_STYLES = {
  default: "border-[#e5e7eb]",
  amber:   "border-amber-200",
  red:     "border-red-200",
  green:   "border-emerald-200",
};

const VALUE_STYLES = {
  default: "text-[#0d0f12]",
  amber:   "text-amber-600",
  red:     "text-red-600",
  green:   "text-emerald-600",
};

export function MetricCard({ label, value, sub, accent = "default" }: MetricCardProps) {
  return (
    <div className={cn(
      "rounded-lg border bg-white p-5 flex flex-col gap-1",
      ACCENT_STYLES[accent]
    )}>
      <div className="text-[12px] font-medium text-[#6b7280] uppercase tracking-wide">{label}</div>
      <div className={cn("text-2xl font-semibold tracking-tight", VALUE_STYLES[accent])}>
        {typeof value === "number" ? value.toLocaleString() : value}
      </div>
      {sub && <div className="text-[12px] text-[#9ca3af]">{sub}</div>}
    </div>
  );
}
