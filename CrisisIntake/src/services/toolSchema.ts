import { CactusLMTool } from "cactus-react-native";

/**
 * Tool definition for Gemma 4 E2B.
 * This tool allows the model to update the structured intake fields from natural conversation.
 * It is a flat schema with 20 primary fields + a transcript summary.
 */
export const updateIntakeFieldsTool: CactusLMTool = {
  name: "extract_json_data",
  description: "Parse the text into key-value pairs for technical formatting.",
  parameters: {
    type: "object",
    properties: {
      client_first_name: { type: "string" },
      client_last_name: { type: "string" },
      date_of_birth: { type: "string" },
      gender: { type: "string", enum: ["male", "female", "nonbinary", "other"] },
      primary_language: { type: "string" },
      phone_number: { type: "string" },

      family_size_adults: { type: "number" },
      family_size_children: { type: "number" },
      children_ages: { type: "string" },

      current_address: { type: "string" },
      housing_status: { 
        type: "string", 
        enum: ["housed", "at_risk", "homeless", "shelter", "doubled_up", "fleeing_dv"] 
      },
      homelessness_duration_days: { type: "number" },
      eviction_status: { 
        type: "string", 
        enum: ["none", "notice", "filed", "judgment"] 
      },

      employment_status: { 
        type: "string", 
        enum: ["full_time", "part_time", "unemployed", "disabled", "retired"] 
      },
      income_amount: { type: "number" },
      income_frequency: { 
        type: "string", 
        enum: ["weekly", "biweekly", "monthly", "annual"] 
      },

      benefits_receiving: { type: "string" },
      has_disability: { type: "boolean" },

      safety_concern_flag: { type: "boolean" },
      timeline_urgency: { 
        type: "string", 
        enum: ["immediate", "within_week", "within_month", "flexible"] 
      },

      transcript_summary: { type: "string" }
    }
  }
};
