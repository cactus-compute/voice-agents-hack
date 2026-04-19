import { create } from "zustand";
import { IntakeSchema, IntakeField, FieldMeta, FIELD_METADATA } from "../types/intake";
import { TranscriptEntry } from "../types/transcript";
import { CloudAnalysis } from "../types/cloud";
import { createEmptyIntake } from "../utils/createEmptyIntake";
import { mergeExtractedFields } from "../utils/mergeFields";

type PipelinePhase = "idle" | "listening" | "transcribing" | "reviewing" | "extracting" | "scanning";
type CloudStatus = "idle" | "sanitizing" | "sending" | "complete" | "error" | "queued";

interface AppState {
  // Session
  sessionId: string;
  sessionStartedAt: number;

  // Pipeline
  pipelinePhase: PipelinePhase;
  modelsLoaded: boolean;
  modelDownloadProgress: { vad: number; stt: number; llm: number };

  // Audio
  speechSeconds: number;
  silenceSeconds: number;

  // Transcript
  currentTranscript: string | null;
  transcriptLog: TranscriptEntry[];

  // Intake
  intake: IntakeSchema;

  // Cloud
  cloudStatus: CloudStatus;
  cloudResult: CloudAnalysis | null;

  // Actions — Pipeline
  setPipelinePhase: (phase: PipelinePhase) => void;
  setModelsLoaded: (loaded: boolean) => void;
  updateDownloadProgress: (model: "vad" | "stt" | "llm", progress: number) => void;

  // Actions — Audio
  updateAudioCounters: (speech: number, silence: number) => void;
  resetAudioCounters: () => void;

  // Actions — Transcript
  setCurrentTranscript: (text: string) => void;
  editCurrentTranscript: (text: string) => void;
  commitTranscript: (entry: TranscriptEntry) => void;
  clearCurrentTranscript: () => void;

  // Actions — Intake
  mergeFields: (delta: Partial<Record<keyof IntakeSchema, any>>, source: "voice" | "vision") => void;
  confirmField: (key: keyof IntakeSchema) => void;
  confirmAllFields: () => void;
  editField: (key: keyof IntakeSchema, value: any) => void;
  unlockField: (key: keyof IntakeSchema) => void;

  // Actions — Cloud
  setCloudStatus: (status: CloudStatus) => void;
  setCloudResult: (result: CloudAnalysis) => void;

  // Computed
  getCompletionPercentage: () => number;
  getFieldsBySection: (section: string) => Array<{ meta: FieldMeta; field: IntakeField }>;

  // Session
  resetSession: () => void;
}

export const useAppStore = create<AppState>((set, get) => ({
  // Initial state
  sessionId: Date.now().toString(),
  sessionStartedAt: Date.now(),
  pipelinePhase: "idle",
  modelsLoaded: false,
  modelDownloadProgress: { vad: 0, stt: 0, llm: 0 },
  speechSeconds: 0,
  silenceSeconds: 0,
  currentTranscript: null,
  transcriptLog: [],
  intake: createEmptyIntake(),
  cloudStatus: "idle",
  cloudResult: null,

  // Pipeline
  setPipelinePhase: (phase) => set({ pipelinePhase: phase }),
  setModelsLoaded: (loaded) => set({ modelsLoaded: loaded }),
  updateDownloadProgress: (model, progress) =>
    set((s) => ({
      modelDownloadProgress: { ...s.modelDownloadProgress, [model]: progress },
    })),

  // Audio
  updateAudioCounters: (speech, silence) =>
    set({ speechSeconds: speech, silenceSeconds: silence }),
  resetAudioCounters: () => set({ speechSeconds: 0, silenceSeconds: 0 }),

  // Transcript
  setCurrentTranscript: (text) => set({ currentTranscript: text }),
  editCurrentTranscript: (text) => set({ currentTranscript: text }),
  commitTranscript: (entry) =>
    set((s) => ({ transcriptLog: [...s.transcriptLog, entry] })),
  clearCurrentTranscript: () => set({ currentTranscript: null }),

  // Intake
  mergeFields: (delta, source) =>
    set((s) => ({ intake: mergeExtractedFields(s.intake, delta, source) })),

  confirmField: (key) =>
    set((s) => {
      const field = s.intake[key];
      if (field.status !== "inferred") return s;
      return {
        intake: {
          ...s.intake,
          [key]: { ...field, status: "confirmed", lastUpdatedAt: Date.now() },
        },
      };
    }),

  confirmAllFields: () =>
    set((s) => {
      const newIntake = { ...s.intake };
      for (const meta of FIELD_METADATA) {
        const field = newIntake[meta.key];
        if (field.status === "inferred") {
          (newIntake as any)[meta.key] = {
            ...field,
            status: "confirmed",
            lastUpdatedAt: Date.now(),
          };
        }
      }
      return { intake: newIntake };
    }),

  editField: (key, value) =>
    set((s) => ({
      intake: {
        ...s.intake,
        [key]: {
          value,
          status: "inferred",
          lastUpdatedAt: Date.now(),
          source: "manual",
        },
      },
    })),

  unlockField: (key) =>
    set((s) => {
      const field = s.intake[key];
      if (field.status !== "confirmed") return s;
      return {
        intake: {
          ...s.intake,
          [key]: { ...field, status: "inferred", lastUpdatedAt: Date.now() },
        },
      };
    }),

  // Cloud
  setCloudStatus: (status) => set({ cloudStatus: status }),
  setCloudResult: (result) => set({ cloudResult: result }),

  // Computed
  getCompletionPercentage: () => {
    const intake = get().intake;
    const nonEmpty = FIELD_METADATA.filter(
      (m) => intake[m.key].status !== "empty"
    ).length;
    return Math.round((nonEmpty / FIELD_METADATA.length) * 100);
  },

  getFieldsBySection: (section) => {
    const intake = get().intake;
    return FIELD_METADATA.filter((m) => m.section === section).map((meta) => ({
      meta,
      field: intake[meta.key],
    }));
  },

  // Session
  resetSession: () =>
    set({
      sessionId: Date.now().toString(),
      sessionStartedAt: Date.now(),
      pipelinePhase: "idle",
      speechSeconds: 0,
      silenceSeconds: 0,
      currentTranscript: null,
      transcriptLog: [],
      intake: createEmptyIntake(),
      cloudStatus: "idle",
      cloudResult: null,
    }),
}));
