import Link from "next/link";
import { AlertTriangle } from "lucide-react";

export default function AuthErrorPage() {
  return (
    <div className="min-h-screen bg-[#f8fafc] flex items-center justify-center">
      <div className="text-center space-y-4">
        <div className="flex justify-center">
          <div className="bg-red-50 p-4 rounded-full">
            <AlertTriangle className="w-8 h-8 text-red-500" />
          </div>
        </div>
        <h1 className="text-lg font-semibold text-[#0d0f12]">Authentication failed</h1>
        <p className="text-sm text-[#6b7280]">Something went wrong during sign-in.</p>
        <Link
          href="/login"
          className="inline-block text-sm font-medium text-indigo-600 hover:text-indigo-800"
        >
          Try again
        </Link>
      </div>
    </div>
  );
}
