"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  LayoutDashboard,
  MessageSquare,
  Activity,
  FileText,
  ClipboardList,
  KeyRound,
  Key,
  Settings,
  Shield,
} from "lucide-react";
import { cn } from "@/lib/utils";

const NAV = [
  { href: "/overview",      label: "Overview",            icon: LayoutDashboard },
  { href: "/copilot",       label: "Compliance Copilot",  icon: MessageSquare },
  { href: "/sessions",      label: "Sessions",            icon: Activity },
  { href: "/policies",      label: "Policies",            icon: FileText },
  { href: "/audit-reports", label: "Audit Reports",       icon: ClipboardList },
  { href: "/kms",           label: "Managed KMS",         icon: KeyRound },
  { href: "/api-keys",      label: "API Keys",            icon: Key },
  { href: "/settings",      label: "Settings",            icon: Settings },
];

export function Sidebar() {
  const pathname = usePathname();

  return (
    <aside className="flex flex-col w-[220px] shrink-0 border-r border-[#e5e7eb] bg-[#fafafa] h-screen sticky top-0">
      {/* Logo */}
      <div className="flex items-center gap-2.5 px-5 h-14 border-b border-[#e5e7eb]">
        <div className="flex items-center justify-center w-7 h-7 rounded-md bg-[#0d0f12]">
          <Shield className="w-3.5 h-3.5 text-white" />
        </div>
        <span className="text-[13px] font-semibold tracking-tight text-[#0d0f12]">Masker</span>
      </div>

      {/* Nav */}
      <nav aria-label="Main navigation" className="flex flex-col gap-0.5 px-3 py-3 flex-1">
        {NAV.map(({ href, label, icon: Icon }) => {
          const active = pathname === href || pathname.startsWith(href + "/");
          return (
            <Link
              key={href}
              href={href}
              aria-current={active ? "page" : undefined}
              className={cn(
                "flex items-center gap-2.5 px-2.5 py-2 rounded-md text-[13px] font-medium transition-colors",
                active
                  ? "bg-[#0d0f12] text-white"
                  : "text-[#6b7280] hover:bg-[#f0f0f0] hover:text-[#0d0f12]"
              )}
            >
              <Icon className="w-4 h-4 shrink-0" aria-hidden="true" />
              {label}
            </Link>
          );
        })}
      </nav>

      {/* Workspace */}
      <div className="px-4 py-4 border-t border-[#e5e7eb]">
        <div className="text-[11px] text-[#9ca3af] uppercase tracking-wider mb-1">Workspace</div>
        <div className="text-[13px] font-medium text-[#0d0f12]">Acme Health</div>
        <div className="text-[11px] text-[#9ca3af]">acme.masker.io</div>
      </div>
    </aside>
  );
}
