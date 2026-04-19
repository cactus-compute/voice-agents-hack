export interface SanitizedPayload {
  gender: string | null;
  primary_language: string | null;
  family_size_adults: number | null;
  family_size_children: number | null;
  children_ages: string | null;
  housing_status: string | null;
  homelessness_duration_days: number | null;
  eviction_status: string | null;
  employment_status: string | null;
  income_bucket: string | null;
  income_frequency: string | null;
  benefits_receiving: string | null;
  has_disability: boolean | null;
  safety_concern_flag: boolean | null;
  timeline_urgency: string | null;
  fields_confirmed: number;
  fields_total: number;
  completion_percentage: number;
}
