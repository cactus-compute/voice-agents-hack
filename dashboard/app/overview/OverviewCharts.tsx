"use client";

import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  BarChart,
  Bar,
  Cell,
} from "recharts";

interface VolumePoint { date: string; sessions: number }
interface EntityPoint { type: string; count: number }

export function OverviewCharts({
  volumeData,
  entityData,
}: {
  volumeData: VolumePoint[];
  entityData: EntityPoint[];
}) {
  return (
    <div className="flex flex-col gap-6">
      {/* Area chart */}
      <ResponsiveContainer width="100%" height={140}>
        <AreaChart data={volumeData} margin={{ top: 4, right: 4, left: -20, bottom: 0 }}>
          <defs>
            <linearGradient id="sessionGrad" x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stopColor="#0d0f12" stopOpacity={0.08} />
              <stop offset="95%" stopColor="#0d0f12" stopOpacity={0} />
            </linearGradient>
          </defs>
          <XAxis dataKey="date" tick={{ fontSize: 11, fill: "#9ca3af" }} axisLine={false} tickLine={false} />
          <YAxis tick={{ fontSize: 11, fill: "#9ca3af" }} axisLine={false} tickLine={false} />
          <Tooltip
            contentStyle={{ fontSize: 12, border: "1px solid #e5e7eb", borderRadius: 8, boxShadow: "none" }}
            itemStyle={{ color: "#0d0f12" }}
            labelStyle={{ color: "#6b7280", fontWeight: 500 }}
          />
          <Area
            type="monotone"
            dataKey="sessions"
            stroke="#0d0f12"
            strokeWidth={1.5}
            fill="url(#sessionGrad)"
            dot={false}
          />
        </AreaChart>
      </ResponsiveContainer>

      {/* Entity bar chart */}
      <div>
        <div className="text-[12px] font-medium text-[#6b7280] mb-2">Top entity types today</div>
        <ResponsiveContainer width="100%" height={80}>
          <BarChart data={entityData} layout="vertical" margin={{ top: 0, right: 4, left: 60, bottom: 0 }}>
            <XAxis type="number" tick={{ fontSize: 11, fill: "#9ca3af" }} axisLine={false} tickLine={false} />
            <YAxis type="category" dataKey="type" tick={{ fontSize: 11, fill: "#6b7280" }} axisLine={false} tickLine={false} width={60} />
            <Tooltip
              contentStyle={{ fontSize: 12, border: "1px solid #e5e7eb", borderRadius: 8, boxShadow: "none" }}
              cursor={{ fill: "#f9fafb" }}
            />
            <Bar dataKey="count" radius={[0, 3, 3, 0]} maxBarSize={10}>
              {entityData.map((_, i) => (
                <Cell key={i} fill={i === 0 ? "#0d0f12" : "#d1d5db"} />
              ))}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
