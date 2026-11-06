'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');

test('Seconds no longer installs a per-user one-open-position restriction', () => {
  const retired = read('supabase/sql/0015_financial_seconds_one_open_position_v1.sql');
  const schema = read('supabase/sql/0014_financial_seconds_contracts_v1.sql');
  const policy = read('supabase/sql/0025_seconds_policy_versioning_v1.sql');
  assert.match(retired, /retired legacy single-open-position restriction/i);
  assert.doesNotMatch(retired, /CREATE UNIQUE INDEX/i);
  assert.doesNotMatch(retired, /OPEN_POSITION_EXISTS|one_open_per_user_idx\s+ON/i);
  assert.doesNotMatch(schema, /CREATE UNIQUE INDEX[^;]*seconds_contract_positions[^;]*user_id[^;]*status/i);
  assert.doesNotMatch(policy, /seconds_contract_positions_one_open_per_user_idx|OPEN_POSITION_EXISTS/);
  assert.match(policy, /per_user_open_exposure/);
});

test('Seconds positions API returns all open positions as an array', () => {
  const api = read('api-core.js');
  assert.match(api, /open:\s*Array\.isArray\(result\.open\)\s*\?\s*result\.open\s*:\s*\[\]/);
});
