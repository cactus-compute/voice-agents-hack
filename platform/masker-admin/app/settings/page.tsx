import { PageShell } from "@/components/layout/PageShell";
import { Button } from "@/components/ui/Button";

const SECTIONS = [
  {
    title: "Workspace",
    desc: "Name, slug, and billing details for this workspace.",
    fields: [
      { label: "Workspace Name", value: "Acme Health", type: "text" },
      { label: "Slug", value: "acme", type: "text" },
      { label: "Plan", value: "Enterprise", type: "readonly" },
    ],
  },
  {
    title: "Team & RBAC",
    desc: "Manage members and role-based access control.",
    fields: [
      { label: "Members", value: "12 active", type: "readonly" },
      { label: "Default Role", value: "Viewer", type: "text" },
    ],
  },
  {
    title: "Webhooks",
    desc: "Receive real-time events for session and policy changes.",
    fields: [
      { label: "Endpoint URL", value: "https://hooks.acme.io/masker", type: "text" },
      { label: "Events", value: "session.flagged, policy.published", type: "text" },
    ],
  },
  {
    title: "SIEM Export",
    desc: "Stream audit events to your SIEM or log aggregator.",
    fields: [
      { label: "Destination", value: "Splunk HEC", type: "readonly" },
      { label: "Status", value: "Connected", type: "readonly" },
    ],
  },
  {
    title: "Retention",
    desc: "Configure how long session data and audit logs are retained.",
    fields: [
      { label: "Session Logs", value: "90 days", type: "text" },
      { label: "Audit Trail", value: "365 days", type: "text" },
      { label: "Masked Transcripts", value: "30 days", type: "text" },
    ],
  },
  {
    title: "Notifications",
    desc: "Alert rules for policy failures, flagged sessions, and key rotation.",
    fields: [
      { label: "Alert Email", value: "compliance@acme.io", type: "text" },
      { label: "Slack Webhook", value: "#masker-alerts", type: "text" },
    ],
  },
];

export default function SettingsPage() {
  return (
    <PageShell title="Settings">
      <div className="mb-6">
        <h2 className="text-[18px] font-semibold tracking-tight text-[#0d0f12]">Settings</h2>
        <p className="text-[13px] text-[#6b7280] mt-1">Workspace configuration, team access, integrations, and retention.</p>
      </div>

      <div className="flex flex-col gap-4 max-w-2xl">
        {SECTIONS.map((section) => (
          <div key={section.title} className="rounded-lg border border-[#e5e7eb] bg-white overflow-hidden">
            <div className="px-5 py-4 border-b border-[#e5e7eb]">
              <div className="text-[13px] font-semibold text-[#0d0f12]">{section.title}</div>
              <div className="text-[12px] text-[#9ca3af] mt-0.5">{section.desc}</div>
            </div>
            <div className="px-5 py-4 flex flex-col gap-4">
              {section.fields.map((f) => {
                const id = `${section.title}-${f.label}`.toLowerCase().replace(/\s+/g, "-");
                return (
                  <div key={f.label} className="flex flex-col gap-1">
                    <label
                      htmlFor={f.type !== "readonly" ? id : undefined}
                      className="text-[11px] font-medium text-[#6b7280] uppercase tracking-wide"
                    >
                      {f.label}
                    </label>
                    {f.type === "readonly" ? (
                      <div className="text-[13px] text-[#0d0f12] font-medium">{f.value}</div>
                    ) : (
                      <input
                        id={id}
                        defaultValue={f.value}
                        className="text-[13px] text-[#0d0f12] border border-[#e5e7eb] rounded-md px-3 py-2 outline-none focus:border-[#0d0f12] transition-colors bg-white"
                      />
                    )}
                  </div>
                );
              })}
              <div className="pt-1">
                <Button size="sm" variant="secondary">Save Changes</Button>
              </div>
            </div>
          </div>
        ))}
      </div>
    </PageShell>
  );
}
