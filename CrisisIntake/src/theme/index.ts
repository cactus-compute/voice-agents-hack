export const theme = {
  colors: {
    fieldEmpty: "#F3F4F6",
    fieldEmptyBorder: "#E5E7EB",
    fieldInferred: "#FFFBEB",
    fieldInferredBorder: "#F59E0B",
    fieldInferredAccent: "#D97706",
    fieldConfirmed: "#ECFDF5",
    fieldConfirmedBorder: "#10B981",
    fieldConfirmedAccent: "#059669",

    background: "#FFFFFF",
    surface: "#F9FAFB",
    textPrimary: "#111827",
    textSecondary: "#6B7280",
    textMuted: "#9CA3AF",
    accent: "#3B82F6",
    danger: "#EF4444",
    dangerLight: "#FEE2E2",

    riskLow: "#10B981",
    riskMedium: "#F59E0B",
    riskHigh: "#EF4444",
  },

  spacing: {
    xs: 4,
    sm: 8,
    md: 16,
    lg: 24,
    xl: 32,
    xxl: 48,
  },

  radii: {
    sm: 8,
    md: 12,
    lg: 16,
    xl: 24,
    full: 9999,
  },

  typography: {
    h1: { fontSize: 28, fontWeight: "700" as const, letterSpacing: -0.5 },
    h2: { fontSize: 22, fontWeight: "600" as const, letterSpacing: -0.3 },
    h3: { fontSize: 17, fontWeight: "600" as const },
    body: { fontSize: 15, fontWeight: "400" as const },
    caption: { fontSize: 13, fontWeight: "500" as const, letterSpacing: 0.5 },
    sectionHeader: {
      fontSize: 12,
      fontWeight: "600" as const,
      letterSpacing: 1,
      textTransform: "uppercase" as const,
    },
  },

  shadows: {
    card: {
      shadowColor: "#000",
      shadowOffset: { width: 0, height: 1 },
      shadowOpacity: 0.05,
      shadowRadius: 3,
      elevation: 2,
    },
    elevated: {
      shadowColor: "#000",
      shadowOffset: { width: 0, height: 4 },
      shadowOpacity: 0.08,
      shadowRadius: 12,
      elevation: 4,
    },
  },
};
