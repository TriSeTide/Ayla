import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// dev proxy：前端同源访问 /api 与 /ws，转发到 Django 后端
// 后端 ALLOWED_HOSTS=["*"] 已放行，本地 dev 无需 CORS
const BACKEND_ORIGIN = process.env.VITE_DEV_PROXY_TARGET ?? "http://127.0.0.1:8000";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: BACKEND_ORIGIN,
        changeOrigin: true,
      },
      "/ws": {
        target: BACKEND_ORIGIN.replace(/^http/, "ws"),
        ws: true,
        changeOrigin: true,
      },
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/vitest/setup.ts"],
    css: false,
  },
});
