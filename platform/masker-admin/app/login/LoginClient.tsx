"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { GitBranch } from "lucide-react";

function GoogleIcon() {
  return (
    <svg className="w-4 h-4" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" fill="#4285F4"/>
      <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853"/>
      <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.84z" fill="#FBBC05"/>
      <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335"/>
    </svg>
  );
}

export function LoginClient() {
  const [loading, setLoading] = useState<"github" | "google" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const supabase = createClient();

  async function signIn(provider: "github" | "google") {
    setLoading(provider);
    setError(null);
    const { error } = await supabase.auth.signInWithOAuth({
      provider,
      options: {
        redirectTo: `${window.location.origin}/auth/callback`,
      },
    });
    if (error) {
      setError(error.message);
      setLoading(null);
    }
  }

  return (
    <div className="min-h-screen bg-[#f8fafc] flex">
      {/* Left — branding */}
      <div className="hidden lg:flex flex-col justify-between w-[480px] bg-[#0d0f12] p-12 shrink-0">
        <div>
          <div className="flex items-center gap-2.5 mb-16">
            <span className="text-2xl">🛡️</span>
            <span className="text-white font-semibold text-lg tracking-tight">Masker</span>
          </div>
          <h1 className="text-[32px] font-semibold text-white leading-tight mb-4">
            Programmable privacy<br />for voice agents
          </h1>
          <p className="text-[15px] text-[#9ca3af] leading-relaxed">
            Drop-in HIPAA, GDPR, and PCI compliance. Detect PII, mask in real-time, and ship full audit trails — in one SDK call.
          </p>
        </div>

        <div className="space-y-4">
          {[
            { label: "Entity detection", value: "SSN, DOB, CC, MRN, 40+ types" },
            { label: "Masking modes", value: "mask · redact · tokenize · block" },
            { label: "Audit trail", value: "Immutable, per-session, exportable" },
            { label: "Frameworks", value: "HIPAA · GDPR · PCI · Custom" },
          ].map(({ label, value }) => (
            <div key={label} className="flex items-center justify-between text-[13px]">
              <span className="text-[#6b7280]">{label}</span>
              <span className="text-[#d1d5db] font-mono">{value}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Right — auth */}
      <div className="flex-1 flex items-center justify-center p-8">
        <div className="w-full max-w-sm">
          {/* Mobile logo */}
          <div className="flex items-center gap-2 mb-10 lg:hidden">
            <span className="text-2xl">🛡️</span>
            <span className="font-semibold text-lg text-[#0d0f12]">Masker</span>
          </div>

          <h2 className="text-[22px] font-semibold text-[#0d0f12] mb-1">Get started</h2>
          <p className="text-[14px] text-[#6b7280] mb-8">
            Sign in to your workspace or create a new one.
          </p>

          <div className="space-y-3">
            <button
              onClick={() => signIn("github")}
              disabled={loading !== null}
              className="w-full flex items-center justify-center gap-3 px-4 py-2.5 rounded-lg border border-[#e5e7eb] bg-white text-[14px] font-medium text-[#0d0f12] hover:bg-[#f9fafb] hover:border-[#d1d5db] transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {loading === "github" ? (
                <span className="w-4 h-4 border-2 border-[#0d0f12] border-t-transparent rounded-full animate-spin" />
              ) : (
                <GitBranch className="w-4 h-4" />
              )}
              Continue with GitHub
            </button>

            <button
              onClick={() => signIn("google")}
              disabled={loading !== null}
              className="w-full flex items-center justify-center gap-3 px-4 py-2.5 rounded-lg border border-[#e5e7eb] bg-white text-[14px] font-medium text-[#0d0f12] hover:bg-[#f9fafb] hover:border-[#d1d5db] transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {loading === "google" ? (
                <span className="w-4 h-4 border-2 border-[#0d0f12] border-t-transparent rounded-full animate-spin" />
              ) : (
                <GoogleIcon />
              )}
              Continue with Google
            </button>
          </div>

          {error && (
            <p className="mt-4 text-[13px] text-red-600 text-center">{error}</p>
          )}

          <p className="mt-8 text-[12px] text-[#9ca3af] text-center">
            By signing in you agree to our{" "}
            <a href="#" className="underline hover:text-[#6b7280]">Terms</a>{" "}
            and{" "}
            <a href="#" className="underline hover:text-[#6b7280]">Privacy Policy</a>.
          </p>
        </div>
      </div>
    </div>
  );
}
