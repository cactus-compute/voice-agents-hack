import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ["var(--font-inter)", "Inter", "system-ui", "sans-serif"],
        mono: ["var(--font-mono)", "'JetBrains Mono'", "'Fira Code'", "monospace"],
      },
      colors: {
        border: "hsl(220 13% 91%)",
        background: "hsl(0 0% 100%)",
        foreground: "hsl(224 71% 4%)",
        muted: {
          DEFAULT: "hsl(220 14% 96%)",
          foreground: "hsl(220 9% 46%)",
        },
        card: {
          DEFAULT: "hsl(0 0% 100%)",
          foreground: "hsl(224 71% 4%)",
        },
      },
      borderRadius: {
        lg: "12px",
        md: "8px",
        sm: "6px",
      },
    },
  },
  plugins: [],
};
export default config;
