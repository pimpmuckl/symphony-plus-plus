import js from "@eslint/js";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import globals from "globals";
import tseslint from "typescript-eslint";

const sourceFileGlobs = ["**/*.{js,jsx,ts,tsx}"];
const testFileGlobs = [
  "**/*.{test,spec}.{js,jsx,ts,tsx}",
  "**/*_test.{js,jsx,ts,tsx}",
  "**/__tests__/**/*.{js,jsx,ts,tsx}",
];

const productionCodeQualityRules = {
  complexity: ["error", 12],
  "max-lines": ["error", { max: 600 }],
};

const testCodeQualityRules = {
  complexity: ["error", 16],
  "max-lines": ["error", { max: 900 }],
};

const legacyLineRatchets = {
  "src/components/dashboard/board-wires.tsx": 881,
  "src/types/dashboard.ts": 624,
};

const legacyComplexityRatchets = {
  "src/dashboard/card-detail-dialog.tsx": 35,
  "src/dashboard/dashboard-data.tsx": 14,
  "src/dashboard/dashboard-settings.tsx": 13,
  "src/dashboard/dashboard-shell.tsx": 19,
  "src/dashboard/dashboard-state.tsx": 20,
  "src/dashboard/detail-extras.tsx": 29,
  "src/dashboard/package-detail.tsx": 100,
  "src/dashboard/request-detail.tsx": 44,
  "src/dashboard/solo-detail.tsx": 20,
  "src/dashboard/solo-sessions.tsx": 21,
  "src/dashboard/status-cards.tsx": 15,
  "src/dashboard/status-rail.tsx": 28,
  "src/dashboard/update-animations.tsx": 19,
  "src/dashboard/workstream-cards.tsx": 52,
  "src/components/dashboard/board-wires.tsx": 16,
  "src/components/dashboard/guidance-dialog.tsx": 14,
  "src/components/dashboard/markdown-block.tsx": 18,
  "src/components/dashboard/new-request-dialog.tsx": 17,
  "src/lib/operational-state.ts": 17,
};

export default tseslint.config(
  {
    ignores: ["dist", "node_modules", "../priv/static"],
  },
  {
    files: sourceFileGlobs,
    languageOptions: {
      ecmaVersion: 2022,
      globals: {
        ...globals.browser,
        ...globals.node,
      },
      parserOptions: {
        ecmaFeatures: {
          jsx: true,
        },
      },
      sourceType: "module",
    },
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: sourceFileGlobs,
    rules: productionCodeQualityRules,
  },
  {
    files: testFileGlobs,
    rules: testCodeQualityRules,
  },
  ...Object.entries(legacyLineRatchets).map(([file, max]) => ({
    files: [file],
    rules: {
      "max-lines": ["error", { max }],
    },
  })),
  ...Object.entries(legacyComplexityRatchets).map(([file, max]) => ({
    files: [file],
    rules: {
      complexity: ["error", max],
    },
  })),
  {
    files: ["**/*.{ts,tsx}"],
    plugins: {
      "react-hooks": reactHooks,
      "react-refresh": reactRefresh,
    },
    rules: {
      ...reactHooks.configs["recommended-latest"].rules,
      "react-hooks/refs": "warn",
      "react-hooks/set-state-in-effect": "warn",
      "react-refresh/only-export-components": "off",
    },
  },
);
