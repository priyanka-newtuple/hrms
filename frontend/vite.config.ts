import path from "node:path";

import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  server: {
    host: true,
    port: 5173,
    strictPort: true,
    // Docker Desktop bind mounts (esp. on Windows) don't reliably forward
    // inotify events into the container, so chokidar's default watcher
    // silently stops picking up host-side edits. Polling fixes that at the
    // cost of a bit of CPU — fine for a dev container.
    watch: {
      usePolling: true,
      interval: 300,
    },
  },
});
