export interface CloudAnalysis {
  riskScore: number;
  riskFactors: string[];
  protectiveFactors: string[];
  timeline: TimelineEntry[];
  programMatches: ProgramMatch[];
}

export interface TimelineEntry {
  day: number;
  action: string;
  category: string;
}

export interface ProgramMatch {
  name: string;
  likelihood: "likely" | "possible" | "unlikely";
  reason: string;
}
