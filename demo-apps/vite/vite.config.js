import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    // 0.0.0.0, or the dev server is unreachable from Caddy inside the container.
    host: '0.0.0.0',
    port: Number(process.env.PORT || process.env.DX_APP_PORT || 5173),
    strictPort: true,
    hmr: {
      // HMR connects back over the public hostname, through the proxy on 443 -
      // not to the container port. Without this the page loads and then never
      // updates, which is a maddening thing to debug.
      clientPort: 443,
      protocol: 'wss',
    },
    // Every worktree instance arrives as a different Host; the dev server
    // rejects unknown ones by default.
    allowedHosts: true,
  },
});
