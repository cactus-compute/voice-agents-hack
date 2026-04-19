export type FieldStatus = "empty" | "inferred" | "confirmed";

export interface IntakeField<T = string | number | boolean> {
  value: T | null;
  status: FieldStatus;
  lastUpdatedAt: number;
  source: "voice" | "vision" | "manual" | null;
}

export interface IntakeSchema {
  // Demographics (6 fields)
  client_first_name: IntakeField<string>;
  client_last_name: IntakeField<string>;
  date_of_birth: IntakeField<string>;
  gender: IntakeField<string>;
  primary_language: IntakeField<string>;
  phone_number: IntakeField<string>;

  // Family (3 fields)
  family_size_adults: IntakeField<number>;
  family_size_children: IntakeField<number>;
  children_ages: IntakeField<string>;

  // Housing (4 fields)
  current_address: IntakeField<string>;
  housing_status: IntakeField<string>;
  homelessness_duration_days: IntakeField<number>;
  eviction_status: IntakeField<string>;

  // Income (3 fields)
  employment_status: IntakeField<string>;
  income_amount: IntakeField<number>;
  income_frequency: IntakeField<string>;

  // Benefits (1 field)
  benefits_receiving: IntakeField<string>;

  // Health (1 field)
  has_disability: IntakeField<boolean>;

  // Safety (1 field)
  safety_concern_flag: IntakeField<boolean>;

  // Needs (1 field)
  timeline_urgency: IntakeField<string>;
}

export interface FieldMeta {
  key: keyof IntakeSchema;
  label: string;
  section:
    | "demographics"
    | "family"
    | "housing"
    | "income"
    | "benefits"
    | "health"
    | "safety"
    | "needs";
  type: "text" | "number" | "enum" | "boolean";
  enumValues?: string[];
}

export const FIELD_METADATA: FieldMeta[] = [
  { key: "client_first_name", label: "First Name", section: "demographics", type: "text" },
  { key: "client_last_name", label: "Last Name", section: "demographics", type: "text" },
  { key: "date_of_birth", label: "Date of Birth", section: "demographics", type: "text" },
  { key: "gender", label: "Gender", section: "demographics", type: "enum", enumValues: ["male", "female", "nonbinary", "other"] },
  { key: "primary_language", label: "Primary Language", section: "demographics", type: "text" },
  { key: "phone_number", label: "Phone Number", section: "demographics", type: "text" },
  { key: "family_size_adults", label: "Adults in Household", section: "family", type: "number" },
  { key: "family_size_children", label: "Children in Household", section: "family", type: "number" },
  { key: "children_ages", label: "Children's Ages", section: "family", type: "text" },
  { key: "current_address", label: "Current Address", section: "housing", type: "text" },
  { key: "housing_status", label: "Housing Status", section: "housing", type: "enum", enumValues: ["housed", "at_risk", "homeless", "shelter", "doubled_up", "fleeing_dv"] },
  { key: "homelessness_duration_days", label: "Days Homeless", section: "housing", type: "number" },
  { key: "eviction_status", label: "Eviction Status", section: "housing", type: "enum", enumValues: ["none", "notice", "filed", "judgment"] },
  { key: "employment_status", label: "Employment", section: "income", type: "enum", enumValues: ["full_time", "part_time", "unemployed", "disabled", "retired"] },
  { key: "income_amount", label: "Income Amount", section: "income", type: "number" },
  { key: "income_frequency", label: "Income Frequency", section: "income", type: "enum", enumValues: ["weekly", "biweekly", "monthly", "annual"] },
  { key: "benefits_receiving", label: "Benefits", section: "benefits", type: "text" },
  { key: "has_disability", label: "Disability", section: "health", type: "boolean" },
  { key: "safety_concern_flag", label: "Safety Concern", section: "safety", type: "boolean" },
  { key: "timeline_urgency", label: "Urgency", section: "needs", type: "enum", enumValues: ["immediate", "within_week", "within_month", "flexible"] },
];
