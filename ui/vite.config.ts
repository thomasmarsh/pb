import { defineConfig } from "vite";
import { resolve } from "path";
import solid from "vite-plugin-solid";

export default defineConfig({
  plugins: [solid()],
  build: {
    outDir: "../cli/pb_cli/explorer/static/dist",
    emptyOutDir: true,
    lib: {
      entry: resolve(__dirname, "src/App.tsx"),
      formats: ["es"],
    },
    rollupOptions: {
      output: {
        entryFileNames: "[name].js",
      },
    },
  },
  test: {
    environment: "happy-dom",
    include: ["tests/**/*.test.{ts,tsx}"],
    setupFiles: ["tests/setup.ts"],
  },
});
