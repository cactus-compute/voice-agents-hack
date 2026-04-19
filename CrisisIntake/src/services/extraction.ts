import { CactusLM } from "cactus-react-native";
// @ts-ignore - accessing internal CactusFileSystem for direct download
import { CactusFileSystem } from "cactus-react-native/lib/module/native/index.js";
import { IntakeSchema } from "../types/intake";
import { updateIntakeFieldsTool } from "./toolSchema";
import { parseExtractionResult } from "./parseToolCall";

// Direct HuggingFace URL for Gemma 4 E2B INT4 weights
// We bypass the SDK registry because Gemma 4 E2B only ships INT4 (no INT8)
// and the registry requires both to exist.
const GEMMA4_MODEL_NAME = "gemma-4-e2b-it-int4";
const GEMMA4_HF_URL = "https://huggingface.co/Cactus-Compute/gemma-4-E2B-it/resolve/main/weights/gemma-4-e2b-it-int4.zip";

export class ExtractionEngine {
  private lm: CactusLM | null = null;
  private isModelLoading = false;

  constructor() {}

  /**
   * Downloads and initializes the Gemma 4 E2B model.
   * We bypass the CactusLM.download() registry lookup and use CactusFileSystem directly.
   */
  async loadModels(onProgress?: (progress: number) => void): Promise<void> {
    if (this.lm || this.isModelLoading) return;
    
    this.isModelLoading = true;
    try {
      // Step 1: Check if model is already downloaded
      const alreadyExists = await CactusFileSystem.modelExists(GEMMA4_MODEL_NAME);
      
      if (alreadyExists) {
        console.log("[ExtractionEngine] Gemma 4 E2B already downloaded.");
        if (onProgress) onProgress(100);
      } else {
        console.log("[ExtractionEngine] Downloading Gemma 4 E2B from HuggingFace...");
        await CactusFileSystem.downloadModel(
          GEMMA4_MODEL_NAME, 
          GEMMA4_HF_URL, 
          (p: number) => {
            if (onProgress) onProgress(Math.round(p * 100));
          }
        );
        console.log("[ExtractionEngine] Download complete.");
      }

      // Step 2: Get the local path and create a CactusLM pointing to it
      const modelPath = await CactusFileSystem.getModelPath(GEMMA4_MODEL_NAME);
      console.log("[ExtractionEngine] Model path:", modelPath);

      // Use file path directly — this skips the registry lookup entirely
      this.lm = new CactusLM({
        model: modelPath,
      });
      
      await this.lm.init();
      
      console.log("[ExtractionEngine] Gemma 4 E2B loaded successfully.");
    } catch (error) {
      console.error("[ExtractionEngine] Failed to load models:", error);
      this.lm = null;
      throw error;
    } finally {
      this.isModelLoading = false;
    }
  }

  /**
   * Extracts data from a transcript segment using Gemma 4 on-device inference.
   */
  async extractFromTranscript(
    transcript: string,
    currentFields: IntakeSchema
  ): Promise<Partial<Record<keyof IntakeSchema, any>> | null> {
    if (!this.lm) {
      console.warn("[ExtractionEngine] Model not loaded.");
      return null;
    }

    console.log(`[ExtractionEngine] Starting extraction with transcript: "${transcript}"`);
    try {
      // Build context of known fields
      const knownFields = Object.entries(currentFields)
        .filter(([_, field]) => field.status !== "empty")
        .map(([key, field]) => `${key}: ${field.value}`)
        .join(", ");

      const context = knownFields ? `Known: ${knownFields}. ` : "";

      // User-only messages — no system prompt (matches official Cactus SDK pattern)
      const messages = [
        { 
          role: "user" as const, 
          content: `${context}Extract structured data from: "${transcript}"` 
        }
      ];
      
      console.log("[ExtractionEngine] Messages built, calling lm.complete()...");
      
      const result = await this.lm.complete({
        messages,
        tools: [updateIntakeFieldsTool],
      });

      console.log("[ExtractionEngine] Raw result from LM:", JSON.stringify(result, null, 2));

      const parsed = parseExtractionResult(result);
      console.log("[ExtractionEngine] Parsed Delta:", parsed);
      
      return parsed;
    } catch (error) {
      console.error("[ExtractionEngine] Extraction failed:", error);
      return null;
    }
  }

  /**
   * Extracts data from a document image using Gemma 4 vision capabilities.
   */
  async extractFromImage(
    imagePath: string,
    currentFields: IntakeSchema
  ): Promise<Partial<Record<keyof IntakeSchema, any>> | null> {
    if (!this.lm) return null;

    try {
      const result = await this.lm.complete({
        messages: [
          { role: "user" as const, content: "Extract data from this document.", images: [imagePath] }
        ],
        tools: [updateIntakeFieldsTool],
      });

      return parseExtractionResult(result);
    } catch (error) {
      console.error("[ExtractionEngine] Vision extraction failed:", error);
      return null;
    }
  }

  isReady(): boolean {
    return this.lm !== null;
  }

  async destroy(): Promise<void> {
    if (this.lm) {
      await this.lm.destroy();
      this.lm = null;
    }
  }
}

// Singleton instance for easy integration across the app
export const extractionEngine = new ExtractionEngine();
