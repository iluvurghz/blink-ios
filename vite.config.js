import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// main.jsx loads App.jsx only after the entry script has run: hint it in index.html so the browser
// fetches both at once (one round trip less, which is most of it from the Far East to Sweden).
const preloadApp = {
  name: 'blink-preload-app',
  apply: 'build',
  transformIndexHtml(html, ctx) {
    const app = ctx.bundle && Object.values(ctx.bundle).find((c) => c.type === 'chunk' && /[\\/]src[\\/]App\.jsx$/.test(c.facadeModuleId || ''));
    if (!app) return html;
    return { html, tags: [{ tag: 'link', attrs: { rel: 'modulepreload', crossorigin: true, href: './' + app.fileName }, injectTo: 'head' }] };
  },
};

export default defineConfig({
  plugins: [react(), preloadApp],
  base: './',
  build: { outDir: 'dist', emptyOutDir: true, chunkSizeWarningLimit: 1500 },
});
