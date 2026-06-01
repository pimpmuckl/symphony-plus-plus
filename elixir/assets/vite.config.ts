import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import type { IncomingMessage, ServerResponse } from "node:http";
import path from "node:path";
import { defineConfig } from "vite";

const apiOrigin = process.env.SYMPP_API_ORIGIN || "http://127.0.0.1:19998";
const dashboardPort = 19999;
const boardPath = "/sympp/board";
const operatorProxy = {
  "/api": apiOrigin,
  "/mcp": apiOrigin,
  "/sympp/board/session": apiOrigin,
  "/sympp/work-packages": apiOrigin,
};

function redirectBoardRoot(req: IncomingMessage, res: ServerResponse, next: () => void) {
  const url = new URL(req.url || "/", "http://spp.localhost");

  if (url.pathname === "/") {
    res.statusCode = 302;
    res.setHeader("Location", `${boardPath}${url.search}`);
    res.end();
    return;
  }

  next();
}

export default defineConfig({
  plugins: [
    {
      name: "sympp-board-root-redirect",
      configureServer(server) {
        server.middlewares.use(redirectBoardRoot);
      },
      configurePreviewServer(server) {
        server.middlewares.use(redirectBoardRoot);
      },
    },
    tailwindcss(),
    react(),
  ],
  server: {
    host: "127.0.0.1",
    port: dashboardPort,
    strictPort: true,
    allowedHosts: ["spp.localhost"],
    proxy: operatorProxy,
  },
  preview: {
    host: "127.0.0.1",
    port: dashboardPort,
    strictPort: true,
    allowedHosts: ["spp.localhost"],
    proxy: operatorProxy,
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
