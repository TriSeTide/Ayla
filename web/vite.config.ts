import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// dev proxy：前端同源访问 /api 与 /ws，转发到 Django 后端
// 默认 8100（Ayla 后端实际端口；8000 被 Elysium 主进程占用，勿用）
// 后端 ALLOWED_HOSTS=["*"] 已放行，本地 dev 无需 CORS
const BACKEND_ORIGIN = process.env.VITE_DEV_PROXY_TARGET ?? "http://127.0.0.1:8100";

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
      // 媒体数据面：预签名直传/播放走 MinIO（同源代理，规避浏览器跨源与
      // Private Network Access 策略差异；node 流式 pipe 不缓冲不落盘）。
      // rewrite 剥掉 /minio 前缀，还原对象存储真实 key 路径。
      "/minio": {
        target: process.env.VITE_MINIO_PROXY_TARGET ?? "http://127.0.0.1:9000",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/minio/, ""),
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
