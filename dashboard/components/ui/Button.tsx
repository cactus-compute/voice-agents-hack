import { cn } from "@/lib/utils";

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "primary" | "secondary" | "ghost" | "destructive";
  size?: "sm" | "md";
}

const VARIANTS = {
  primary:     "bg-[#0d0f12] text-white hover:bg-[#1f2937] border-transparent",
  secondary:   "bg-white text-[#0d0f12] border-[#e5e7eb] hover:bg-[#f9fafb]",
  ghost:       "bg-transparent text-[#6b7280] border-transparent hover:bg-[#f3f4f6] hover:text-[#0d0f12]",
  destructive: "bg-red-600 text-white hover:bg-red-700 border-transparent",
};

const SIZES = {
  sm: "px-3 py-1.5 text-[12px]",
  md: "px-4 py-2 text-[13px]",
};

export function Button({
  variant = "secondary",
  size = "md",
  className,
  children,
  ...props
}: ButtonProps) {
  return (
    <button
      className={cn(
        "inline-flex items-center gap-1.5 font-medium rounded-md border transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed",
        VARIANTS[variant],
        SIZES[size],
        className
      )}
      {...props}
    >
      {children}
    </button>
  );
}
