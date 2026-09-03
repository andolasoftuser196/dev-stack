'use strict';

const express = require('express');
const { status } = require('./status');

const app = express();

// $PORT is set by the runtime entrypoint from runtime.app_port, and 0.0.0.0 is
// not optional: binding 127.0.0.1 inside a container makes the process
// unreachable from Caddy, which presents as a 502 with nothing whatsoever in
// the application log.
const PORT = Number(process.env.PORT || process.env.DX_APP_PORT || 3000);
const HOST = '0.0.0.0';

app.get('/', async (_req, res) => {
  res.type('text/plain').send(await status('express'));
});

// Deliberately no /healthz. Caddy answers it in front of this process, and it
// has to keep answering while this process is restarting - which is exactly
// when a healthcheck routed through here would take the container down.

app.listen(PORT, HOST, () => {
  console.log(JSON.stringify({
    level: 'info', msg: 'listening', port: PORT, instance: process.env.DX_INSTANCE || 'main',
  }));
});
