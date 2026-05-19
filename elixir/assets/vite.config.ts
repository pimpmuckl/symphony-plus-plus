import react from "@vitejs/plugin-react";
import path from "node:path";
import { defineConfig } from "vite";

const apiOrigin = process.env.SYMPP_API_ORIGIN || "http://127.0.0.1:4057";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    proxy: {
      "/api": apiOrigin,
      "/mcp": apiOrigin,
      "/sympp/board/session": apiOrigin,
      "/sympp/work-packages": apiOrigin,
    },
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  build: {
    outDir: "../priv/static",
    emptyOutDir: false,
    manifest: true,
    rollupOptions: {
      output: {
        entryFileNames: "assets/[name]-[hash].js",
        chunkFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
      },
    },
  },
});
