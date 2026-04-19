export type Json = string | number | boolean | null | { [key: string]: Json } | Json[];

export interface Database {
  public: {
    Tables: {
      orgs: {
        Row: {
          id: string;
          name: string;
          slug: string;
          owner_id: string;
          framework: string;
          created_at: string;
        };
        Insert: Omit<Database["public"]["Tables"]["orgs"]["Row"], "id" | "created_at">;
        Update: Partial<Database["public"]["Tables"]["orgs"]["Insert"]>;
      };
      api_keys: {
        Row: {
          id: string;
          org_id: string;
          label: string;
          key_hash: string;
          prefix: string;
          permissions: string[];
          environment: string;
          status: "active" | "revoked";
          last_used_at: string | null;
          created_at: string;
        };
        Insert: Omit<Database["public"]["Tables"]["api_keys"]["Row"], "id" | "created_at">;
        Update: Partial<Database["public"]["Tables"]["api_keys"]["Insert"]>;
      };
      kms_keys: {
        Row: {
          id: string;
          org_id: string;
          alias: string;
          scope: string;
          region: string;
          rotation_cadence: string;
          last_rotated_at: string;
          status: "active" | "rotating" | "disabled";
          provider: "masker" | "byok";
          created_at: string;
        };
        Insert: Omit<Database["public"]["Tables"]["kms_keys"]["Row"], "id" | "created_at">;
        Update: Partial<Database["public"]["Tables"]["kms_keys"]["Insert"]>;
      };
      audit_logs: {
        Row: {
          id: string;
          org_id: string;
          session_id: string;
          channel: string;
          use_case: string;
          policy_version: string;
          status: string;
          risk_level: string;
          entities_detected: number;
          duration: string;
          raw_hash: string;
          redacted_transcript: string;
          entity_spans: Json;
          created_at: string;
        };
        Insert: Omit<Database["public"]["Tables"]["audit_logs"]["Row"], "id" | "created_at">;
        Update: Partial<Database["public"]["Tables"]["audit_logs"]["Insert"]>;
      };
    };
  };
}

// Convenience row types
export type Org = Database["public"]["Tables"]["orgs"]["Row"];
export type ApiKey = Database["public"]["Tables"]["api_keys"]["Row"];
export type KmsKey = Database["public"]["Tables"]["kms_keys"]["Row"];
export type AuditLog = Database["public"]["Tables"]["audit_logs"]["Row"];
