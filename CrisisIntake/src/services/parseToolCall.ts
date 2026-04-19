import { IntakeSchema } from "../types/intake";

/**
 * Parses the raw content from a CactusLM completion result.
 * It looks for either a tool call (functionCalls) or a JSON block in the text.
 * 
 * @param result The completion result from Cactus SDK
 * @returns A partial IntakeSchema delta or null if parsing fails
 */
export function parseExtractionResult(result: any): Partial<Record<keyof IntakeSchema, any>> | null {
  try {
    // 1. Try to extract from native function calls (Primary Path)
    if (result.functionCalls && result.functionCalls.length > 0) {
      const call = result.functionCalls.find((f: any) => f.name === "extract_json_data");
      if (call && call.arguments) {
        return sanitizeDelta(call.arguments);
      }
    }

    // 2. Try to extract from text response (Fallback Path)
    // The model often returns the tool call as text rather than a structured functionCall.
    const text = result.response || "";
    
    // Try to parse the entire response as JSON (most common case with qwen3)
    try {
      const parsed = JSON.parse(text.trim());
      if (parsed.arguments) {
        return sanitizeDelta(parsed.arguments);
      }
      if (parsed.name === "extract_json_data" && parsed.arguments) {
        return sanitizeDelta(parsed.arguments);
      }
      // If it's just a flat object of fields
      return sanitizeDelta(parsed);
    } catch {
      // Not direct JSON, try regex extraction
    }

    // Try to find JSON within markdown code blocks
    const jsonMatch = text.match(/```json\n([\s\S]*?)\n```/) || text.match(/```\n([\s\S]*?)\n```/);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[1]);
      const delta = parsed.arguments || parsed;
      return sanitizeDelta(delta);
    }

    // Try to find a raw JSON object with "arguments" key
    const argsMatch = text.match(/"arguments"\s*:\s*(\{[\s\S]*\})\s*\}/);
    if (argsMatch) {
      const parsed = JSON.parse(argsMatch[1]);
      return sanitizeDelta(parsed);
    }

    // Last resort: find any JSON object
    const anyJson = text.match(/\{[\s\S]*\}/);
    if (anyJson) {
      const parsed = JSON.parse(anyJson[0]);
      const delta = parsed.arguments || parsed;
      return sanitizeDelta(delta);
    }

    return null;
  } catch (error) {
    console.warn("[Parser] Failed to parse extraction result:", error);
    return null;
  }
}

/**
 * Valid keys from our intake schema.
 */
const VALID_KEYS = new Set([
  'client_first_name', 'client_last_name', 'date_of_birth', 'gender',
  'primary_language', 'phone_number', 'family_size_adults', 'family_size_children',
  'children_ages', 'current_address', 'housing_status', 'homelessness_duration_days',
  'eviction_status', 'employment_status', 'income_amount', 'income_frequency',
  'benefits_receiving', 'has_disability', 'safety_concern_flag', 'timeline_urgency',
  'transcript_summary'
]);

/**
 * Ensures the extracted data matches our schema types and removes garbage.
 */
function sanitizeDelta(raw: any): Partial<Record<keyof IntakeSchema, any>> {
  const sanitized: any = {};
  
  for (const [key, value] of Object.entries(raw)) {
    // Only keep keys that exist in our schema
    if (!VALID_KEYS.has(key)) continue;
    
    // Skip empty, null, undefined, or "unknown" values
    if (value === null || value === undefined || value === "" || value === "unknown") continue;
    
    // Type normalization
    if (key.includes("family_size") || key === "income_amount" || key === "homelessness_duration_days") {
      const num = Number(value);
      if (!isNaN(num)) sanitized[key] = num;
      continue;
    }

    if (key === "safety_concern_flag" || key === "has_disability") {
      sanitized[key] = String(value).toLowerCase() === "true" || value === true;
      continue;
    }

    sanitized[key] = value;
  }

  return sanitized;
}
