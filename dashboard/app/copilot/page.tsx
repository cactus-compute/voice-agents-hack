import { PageShell } from "@/components/layout/PageShell";
import { CopilotClient } from "./CopilotClient";

export default function CopilotPage() {
  return (
    <PageShell title="Compliance Copilot">
      <div className="mb-4">
        <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12]">
          Describe your use case. Get a production-ready policy.
        </h2>
        <p className="text-[13px] text-[#6b7280] mt-1">
          Tell the copilot what you are building. It will propose a structured compliance configuration you can review, test, and publish.
        </p>
      </div>
      <CopilotClient />
    </PageShell>
  );
}
