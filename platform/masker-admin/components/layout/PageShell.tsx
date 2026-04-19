import { Topbar } from "./Topbar";

export function PageShell({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex flex-col flex-1 min-h-screen overflow-hidden">
      <Topbar title={title} />
      <main className="flex-1 overflow-y-auto p-6 bg-white">
        {children}
      </main>
    </div>
  );
}
