'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { status } = require('../status');

test('renders the agreed status shape', async () => {
  const out = await status('next');
  assert.match(out, /^dx demo app/);
  assert.match(out, /runtime=/);
  assert.match(out, /instance=/);
});

test('the suite runs against a disposable database', () => {
  const db = process.env.DB_DATABASE;
  if (!db) return;                                  // no database configured
  // The same guard dx enforces, asserted from inside the project.
  assert.match(db, /(_test|_sandbox)$/,
    'the suite must never point at the development database');
});
