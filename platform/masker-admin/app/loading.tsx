export default function Loading() {
  return (
    <div className="flex flex-col flex-1 overflow-hidden">
      {/* Topbar skeleton */}
      <div className="flex items-center justify-between h-14 px-6 border-b border-[#e5e7eb] bg-white shrink-0">
        <div className="h-4 w-32 bg-gray-100 rounded animate-pulse" />
        <div className="flex items-center gap-3">
          <div className="h-8 w-52 bg-gray-100 rounded-md animate-pulse" />
          <div className="h-8 w-28 bg-gray-100 rounded-md animate-pulse" />
          <div className="h-8 w-8 bg-gray-100 rounded-md animate-pulse" />
          <div className="h-8 w-8 bg-gray-100 rounded-full animate-pulse" />
        </div>
      </div>

      {/* Page content skeleton */}
      <main className="flex-1 overflow-y-auto p-6 bg-white">
        {/* Page heading */}
        <div className="mb-6">
          <div className="h-6 w-64 bg-gray-100 rounded animate-pulse mb-2" />
          <div className="h-4 w-96 bg-gray-100 rounded animate-pulse" />
        </div>

        {/* Metric cards */}
        <div className="grid grid-cols-3 xl:grid-cols-6 gap-3 mb-6">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="rounded-lg border border-[#e5e7eb] p-5 flex flex-col gap-2">
              <div className="h-3 w-24 bg-gray-100 rounded animate-pulse" />
              <div className="h-7 w-16 bg-gray-100 rounded animate-pulse" />
              <div className="h-3 w-20 bg-gray-100 rounded animate-pulse" />
            </div>
          ))}
        </div>

        {/* Table skeleton */}
        <div className="rounded-lg border border-[#e5e7eb] overflow-hidden">
          <div className="h-10 bg-[#fafafa] border-b border-[#e5e7eb]" />
          {Array.from({ length: 5 }).map((_, i) => (
            <div key={i} className="flex items-center gap-4 px-5 py-3.5 border-b border-[#f9fafb] last:border-0">
              <div className="h-3 w-28 bg-gray-100 rounded animate-pulse" />
              <div className="h-3 w-20 bg-gray-100 rounded animate-pulse" />
              <div className="h-3 w-24 bg-gray-100 rounded animate-pulse" />
              <div className="h-3 w-16 bg-gray-100 rounded animate-pulse" />
              <div className="h-5 w-14 bg-gray-100 rounded animate-pulse ml-auto" />
            </div>
          ))}
        </div>
      </main>
    </div>
  );
}
