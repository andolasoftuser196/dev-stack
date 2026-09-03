'use strict';

const test = require('node:test');
const assert = require('node:assert');

test('the suite runs against a disposable database', () => {
  const db = process.env.DB_DATABASE;
  if (!db) return;
  assert.match(db, /(_test|_sandbox)$/,
    'the suite must never point at the development database');
});

test('the compiled entrypoints the queue and scheduler roles expect are declared', () => {
  const pkg = require('../package.json');
  assert.ok(pkg.scripts.queue, 'package.json must declare a queue script');
  assert.ok(pkg.scripts.schedule, 'package.json must declare a schedule script');
});
