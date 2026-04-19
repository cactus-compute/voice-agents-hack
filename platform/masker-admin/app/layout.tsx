import type { Metadata, Viewport } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import { Sidebar } from "@/components/layout/Sidebar";
import { createClient } from "@/lib/supabase/server";

const inter = Inter({ subsets: ["latin"], variable: "--font-inter", display: "swap" });
const jetbrainsMono = JetBrains_Mono({ subsets: ["latin"], variable: "--font-mono", display: "swap" });

export const metadata: Metadata = {
  title: "Masker — Compliance Dashboard",
  description: "Real-time privacy and compliance layer for voice and text AI",
};

export const viewport: Viewport = { width: "device-width", initialScale: 1 };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  // Fetch org for authenticated users — null on public pages (login/onboarding)
  let orgName: string | null = null;
  let orgSlug: string | null = null;
  let userEmail: string | null = null;

  try {
    const supabase = createClient();
    const { data: { user } } = await supabase.auth.getUser();
    if (user) {
      userEmail = user.email ?? null;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data: rawOrg } = await (supabase as any)
        .from("orgs")
        .select("name, slug")
        .eq("owner_id", user.id)
        .maybeSingle();
      const org = rawOrg as { name: string; slug: string } | null;
      orgName = org?.name ?? null;
      orgSlug = org?.slug ?? null;
    }
  } catch {
    // Not authenticated — public page, skip
  }

  const showShell = orgName !== null;

  return (
    <html lang="en" className={`${inter.variable} ${jetbrainsMono.variable}`}>
      <body>
        {showShell ? (
          <div className="flex h-screen overflow-hidden bg-white">
            <Sidebar orgName={orgName!} orgSlug={orgSlug!} userEmail={userEmail} />
            <div className="flex flex-col flex-1 overflow-hidden">
              {children}
            </div>
          </div>
        ) : (
          // Login / onboarding — no shell
          <>{children}</>
        )}
      </body>
    </html>
  );
}
