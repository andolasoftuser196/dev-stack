// The ssmd demo status probe, shared by every Node demo app.
//
// Each check opens a real connection. "The container is running" is what
// `ssmd verify` already covers, and it is not the question anyone is asking when
// they open this page.
'use strict';

const net = require('node:net');

function reachable(host, port, timeout = 5000) {
  return new Promise((resolve) => {
    const s = net.createConnection({ host, port });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.setTimeout(timeout);
    s.on('connect', () => done(true));
    s.on('error', () => done(false));
    s.on('timeout', () => done(false));
  });
}

async function probeDatabase() {
  const name = process.env.DB_DATABASE;
  if (!name) return 'database=skipped';
  const host = process.env.DB_HOST;
  const port = Number(process.env.DB_PORT);
  // A TCP probe rather than a driver: pulling in pg or mysql2 just to say
  // "reachable" would make the demo's dependency list larger than the demo.
  return `database=${name} ${(await reachable(host, port)) ? 'ok' : 'FAILED'}`;
}

async function probeCache() {
  if (!process.env.REDIS_HOST) return 'cache=skipped';
  const db = process.env.REDIS_DB || '0';
  const ok = await reachable(process.env.REDIS_HOST, Number(process.env.REDIS_PORT || 6379));
  return `cache=db${db} ${ok ? 'ok' : 'FAILED'}`;
}

async function probeMail() {
  if (!process.env.MAIL_HOST) return 'mail=skipped';
  return `mail=${(await reachable(process.env.MAIL_HOST, Number(process.env.MAIL_PORT || 1025))) ? 'ok' : 'FAILED'}`;
}

async function status(framework) {
  const lines = [
    'ssmd demo app',
    `runtime=${process.env.SSMD_RUNTIME || 'node'} framework=${framework} version=${process.versions.node}`,
    `instance=${process.env.SSMD_INSTANCE || 'main'}`,
    await probeDatabase(),
    await probeCache(),
    await probeMail(),
    `storage=${process.env.S3_ENDPOINT ? 'ok' : 'skipped'}`,
  ];
  return lines.join('\n') + '\n';
}

module.exports = { status, reachable };
