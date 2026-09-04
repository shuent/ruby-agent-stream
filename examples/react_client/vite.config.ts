import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      "/chat": "http://127.0.0.1:3000",
    },
  },
  preview: {
    port: 4173,
    strictPort: true,
    proxy: {
      "/chat": "http://127.0.0.1:3000",
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test/setup.ts",
  },
});
