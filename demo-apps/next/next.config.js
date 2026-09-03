/** @type {import('next').NextConfig} */
module.exports = {
  // The dev server runs behind Caddy, which terminates TLS and forwards the
  // original Host. Without this, Next's dev-origin check rejects requests
  // arriving as <slug>.<domain> - every worktree instance would 400.
  allowedDevOrigins: ['*'],
  output: 'standalone',
};
