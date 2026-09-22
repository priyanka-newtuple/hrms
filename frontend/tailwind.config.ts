import type { Config } from "tailwindcss";

/**
 * Brand tokens taken verbatim from "Newtuple Design Language Guideline.docx":
 * Cobalt Blue #0047AB signature color, white-dominant, Gray 900/600/50
 * neutrals, gradient #0047AB -> #00B8D9 for emphasis only, Inter font family
 * (ExtraLight 200 for H1, Light 300 body/H2, Medium 500 buttons/labels,
 * SemiBold 600 data/headers), rounded-3xl cards, rounded-full buttons,
 * 300ms hover / 500ms transition, ease-in-out.
 */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        cobalt: {
          DEFAULT: "#0047AB",
          light: "#00B8D9",
        },
        gray: {
          900: "#171B21",
          600: "#5B6472",
          50: "#F7F8FA",
        },
        success: "#22C55E",
        highlight: "#EAB308",
        warning: "#F59E0B",
        danger: "#EF4444",
      },
      fontFamily: {
        sans: [
          "Inter",
          "-apple-system",
          "BlinkMacSystemFont",
          "Segoe UI",
          "Roboto",
          "sans-serif",
        ],
      },
      fontWeight: {
        extralight: "200",
        light: "300",
        medium: "500",
        semibold: "600",
      },
      transitionDuration: {
        hover: "300ms",
        transition: "500ms",
      },
      transitionTimingFunction: {
        brand: "ease-in-out",
      },
      borderRadius: {
        card: "1.5rem", // rounded-3xl
      },
      backgroundImage: {
        "cobalt-gradient": "linear-gradient(90deg, #0047AB 0%, #00B8D9 100%)",
      },
    },
  },
  plugins: [],
} satisfies Config;
