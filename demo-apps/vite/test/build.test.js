'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');

test('the dev server is configured to be reachable from the proxy', () => {
  const cfg = fs.readFileSync(new URL('../vite.config.js', import.meta.url), 'utf8');
  assert.match(cfg, /host: '0\.0\.0\.0'/, 'binding localhost makes it unreachable from Caddy');
  assert.match(cfg, /allowedHosts/, 'each worktree instance arrives as a different Host');
});
