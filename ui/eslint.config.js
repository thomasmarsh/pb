import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: ["src/types/ast.generated.ts"],
  },
  {
    rules: {
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
    },
  },
  ...tseslint.configs.recommended,
);
