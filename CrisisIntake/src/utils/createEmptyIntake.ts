import { IntakeSchema, IntakeField, FIELD_METADATA } from "../types/intake";

function emptyField<T>(): IntakeField<T> {
  return { value: null, status: "empty", lastUpdatedAt: 0, source: null };
}

export function createEmptyIntake(): IntakeSchema {
  const intake = {} as IntakeSchema;
  for (const meta of FIELD_METADATA) {
    (intake as any)[meta.key] = emptyField();
  }
  return intake;
}
