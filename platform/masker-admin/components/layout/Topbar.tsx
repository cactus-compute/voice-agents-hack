"use client";

import { useState, useRef, useEffect } from "react";
import { Search, Bell, ChevronDown, Check, LogOut, User, Settings } from "lucide-react";
import { useRouter } from "next/navigation";
import { cn } from "@/lib/utils";

const ENVS = [
  { label: "Production",  color: "bg-emerald-500" },
  { label: "Staging",     color: "bg-amber-400" },
  { label: "Development", color: "bg-blue-400" },
];

const NOTIFICATIONS = [
  { id: 1, text: "2 failed redactions in Healthcare Intake", time: "14 min ago", unread: true },
  { id: 2, text: "KEK masker/usecase/hr is rotating",        time: "1 hr ago",   unread: true },
  { id: 3, text: "HIPAA Readiness report ready to download", time: "3 hr ago",   unread: false },
];

function useClickOutside(ref: React.RefObject<HTMLElement | null>, cb: () => void) {
  useEffect(() => {
    function handler(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) cb();
    }
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [ref, cb]);
}

export function Topbar({ title }: { title: string }) {
  const router = useRouter();
  const [env, setEnv]         = useState(ENVS[0]);
  const [envOpen, setEnvOpen]     = useState(false);
  const [notifOpen, setNotifOpen] = useState(false);
  const [userOpen, setUserOpen]   = useState(false);
  const [search, setSearch]       = useState("");

  const envRef   = useRef<HTMLDivElement>(null);
  const notifRef = useRef<HTMLDivElement>(null);
  const userRef  = useRef<HTMLDivElement>(null);

  useClickOutside(envRef,   () => setEnvOpen(false));
  useClickOutside(notifRef, () => setNotifOpen(false));
  useClickOutside(userRef,  () => setUserOpen(false));

  const unreadCount = NOTIFICATIONS.filter((n) => n.unread).length;

  function handleSearch(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "Enter" && search.trim()) {
      router.push(`/sessions?q=${encodeURIComponent(search.trim())}`);
    }
  }

  return (
    <header className="flex items-center justify-between h-14 px-6 border-b border-[#e5e7eb] bg-white shrink-0 z-20">
      <h1 className="text-[14px] font-semibold text-[#0d0f12]">{title}</h1>

      <div className="flex items-center gap-3">
        {/* Search */}
        <label className="flex items-center gap-2 px-3 py-1.5 rounded-md border border-[#e5e7eb] bg-[#fafafa] text-[#9ca3af] text-[13px] w-52 cursor-text focus-within:border-[#0d0f12] transition-colors">
          <Search className="w-3.5 h-3.5 shrink-0" aria-hidden="true" />
          <input
            type="search"
            aria-label="Search sessions"
            placeholder="Search sessions…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onKeyDown={handleSearch}
            className="flex-1 bg-transparent outline-none text-[#0d0f12] placeholder:text-[#9ca3af] min-w-0"
          />
          <kbd className="text-[11px] bg-[#f0f0f0] px-1.5 py-0.5 rounded text-[#9ca3af] font-sans">↵</kbd>
        </label>

        {/* Environment switcher */}
        <div ref={envRef} className="relative">
          <button
            aria-label="Switch environment"
            aria-expanded={envOpen}
            aria-haspopup="listbox"
            onClick={() => setEnvOpen((o) => !o)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-md border border-[#e5e7eb] bg-[#fafafa] text-[13px] font-medium text-[#0d0f12] cursor-pointer hover:bg-[#f0f0f0] transition-colors"
          >
            <span className={cn("w-1.5 h-1.5 rounded-full shrink-0", env.color)} />
            {env.label}
            <ChevronDown className={cn("w-3.5 h-3.5 text-[#9ca3af] transition-transform", envOpen && "rotate-180")} />
          </button>

          {envOpen && (
            <div
              role="listbox"
              aria-label="Environment"
              className="absolute right-0 top-full mt-1.5 w-44 bg-white border border-[#e5e7eb] rounded-lg shadow-sm py-1 z-50"
            >
              {ENVS.map((e) => (
                <button
                  key={e.label}
                  role="option"
                  aria-selected={env.label === e.label}
                  onClick={() => { setEnv(e); setEnvOpen(false); }}
                  className="flex items-center justify-between w-full px-3 py-2 text-[13px] text-[#0d0f12] hover:bg-[#f9fafb] transition-colors"
                >
                  <span className="flex items-center gap-2">
                    <span className={cn("w-1.5 h-1.5 rounded-full", e.color)} />
                    {e.label}
                  </span>
                  {env.label === e.label && <Check className="w-3.5 h-3.5 text-[#0d0f12]" />}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Notifications */}
        <div ref={notifRef} className="relative">
          <button
            aria-label={`Notifications, ${unreadCount} unread`}
            aria-expanded={notifOpen}
            aria-haspopup="true"
            onClick={() => setNotifOpen((o) => !o)}
            className="relative flex items-center justify-center w-8 h-8 rounded-md border border-[#e5e7eb] bg-[#fafafa] hover:bg-[#f0f0f0] transition-colors"
          >
            <Bell className="w-4 h-4 text-[#6b7280]" aria-hidden="true" />
            {unreadCount > 0 && (
              <span className="absolute top-1 right-1 w-1.5 h-1.5 rounded-full bg-red-500" aria-hidden="true" />
            )}
          </button>

          {notifOpen && (
            <div
              role="dialog"
              aria-label="Notifications"
              className="absolute right-0 top-full mt-1.5 w-80 bg-white border border-[#e5e7eb] rounded-lg shadow-sm z-50 overflow-hidden"
            >
              <div className="flex items-center justify-between px-4 py-3 border-b border-[#f3f4f6]">
                <span className="text-[13px] font-semibold text-[#0d0f12]">Notifications</span>
                <button className="text-[11px] text-[#6b7280] hover:text-[#0d0f12] transition-colors">Mark all read</button>
              </div>
              {NOTIFICATIONS.map((n) => (
                <div
                  key={n.id}
                  className={cn(
                    "flex flex-col gap-0.5 px-4 py-3 border-b border-[#f9fafb] last:border-0",
                    n.unread && "bg-blue-50/40"
                  )}
                >
                  <div className="flex items-start gap-2">
                    {n.unread && <span className="w-1.5 h-1.5 rounded-full bg-blue-500 mt-1.5 shrink-0" aria-hidden="true" />}
                    <p className={cn(
                      "text-[12px] leading-snug",
                      n.unread ? "text-[#0d0f12] font-medium" : "text-[#6b7280] ml-3.5"
                    )}>
                      {n.text}
                    </p>
                  </div>
                  <span className="text-[11px] text-[#9ca3af] ml-3.5">{n.time}</span>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* User menu */}
        <div ref={userRef} className="relative">
          <button
            aria-label="User menu"
            aria-expanded={userOpen}
            aria-haspopup="true"
            onClick={() => setUserOpen((o) => !o)}
            className="flex items-center gap-2 cursor-pointer"
          >
            <div className="w-7 h-7 rounded-full bg-[#0d0f12] flex items-center justify-center text-white text-[11px] font-semibold select-none">
              AH
            </div>
            <ChevronDown className={cn("w-3.5 h-3.5 text-[#9ca3af] transition-transform", userOpen && "rotate-180")} />
          </button>

          {userOpen && (
            <div
              role="menu"
              aria-label="User menu"
              className="absolute right-0 top-full mt-1.5 w-52 bg-white border border-[#e5e7eb] rounded-lg shadow-sm py-1 z-50"
            >
              <div className="px-3 py-2.5 border-b border-[#f3f4f6]">
                <div className="text-[13px] font-medium text-[#0d0f12]">Admin User</div>
                <div className="text-[11px] text-[#9ca3af]">admin@acme.io</div>
              </div>
              {[
                { icon: User,     label: "Profile",  href: "/settings" },
                { icon: Settings, label: "Settings", href: "/settings" },
              ].map(({ icon: Icon, label, href }) => (
                <button
                  key={label}
                  role="menuitem"
                  onClick={() => { router.push(href); setUserOpen(false); }}
                  className="flex items-center gap-2.5 w-full px-3 py-2 text-[13px] text-[#374151] hover:bg-[#f9fafb] transition-colors"
                >
                  <Icon className="w-3.5 h-3.5 text-[#9ca3af]" aria-hidden="true" />
                  {label}
                </button>
              ))}
              <div className="border-t border-[#f3f4f6] mt-1 pt-1">
                <button
                  role="menuitem"
                  className="flex items-center gap-2.5 w-full px-3 py-2 text-[13px] text-red-600 hover:bg-red-50 transition-colors"
                >
                  <LogOut className="w-3.5 h-3.5" aria-hidden="true" />
                  Sign out
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
