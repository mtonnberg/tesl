import { defineConfig, type ViteDevServer } from "vite";
import react from "@vitejs/plugin-react";
import checker from "vite-plugin-checker";
import { execSync } from "child_process";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Tesl codegen plugin
//
// Watches the .tesl source file and re-runs `tesl generate ts` whenever it
// changes.  Vite's HMR then picks up the updated todo-api-client.ts and
// hot-reloads the browser — no manual step needed.
// ---------------------------------------------------------------------------

function teslGeneratePlugin(opts: { teslFile: string; outFile: string }) {
  function regenerate(label = "change") {
    try {
      execSync(
        `tesl generate ts "${opts.teslFile}" --out "${opts.outFile}"`,
        { encoding: "utf8", shell: true },
      );
      console.log(`[tesl] regenerated (${label}) → ${opts.outFile}`);
    } catch (err: unknown) {
      const e = err as { stderr?: string; message?: string };
      console.error("[tesl] generation failed:", e.stderr ?? e.message);
    }
  }

  return {
    name: "tesl-generate",

    // Run once on startup so the client is always in sync when the dev server
    // starts, even if someone edited the .tesl file while the server was off.
    buildStart() {
      regenerate("startup");
    },

    configureServer(server: ViteDevServer) {
      server.watcher.add(opts.teslFile);
      server.watcher.on("change", (file: string) => {
        if (file === opts.teslFile) regenerate(file);
      });
    },
  };
}

export default defineConfig({
  plugins: [
    react(),
    checker({ typescript: true }),
    teslGeneratePlugin({
      teslFile: resolve(__dirname, "../todo-api.tesl"),
      outFile: resolve(__dirname, "src/todo-api-client.ts"),
    }),
  ],
  server: {
    proxy: {
      "/todos": "http://localhost:8086",
    },
  },
});
