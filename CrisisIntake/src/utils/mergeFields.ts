import { IntakeSchema } from "../types/intake";

export function mergeExtractedFields(
  currentState: IntakeSchema,
  delta: Partial<Record<keyof IntakeSchema, any>>,
  source: "voice" | "vision"
): IntakeSchema {
  const newState = { ...currentState };

  for (const [key, value] of Object.entries(delta)) {
    const fieldKey = key as keyof IntakeSchema;
    const currentField = newState[fieldKey];

    if (!currentField) continue;
    if (value === null || value === undefined || value === "") continue;

    // NEVER overwrite confirmed fields
    if (currentField.status === "confirmed") continue;

    newState[fieldKey] = {
      value,
      status: "inferred",
      lastUpdatedAt: Date.now(),
      source,
    };
  }

  return newState;
}
