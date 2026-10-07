// The Lua grading harness (SETUP_LUA in Public/lua-grading-shared.js) run in a
// real Lua, one state for several scripts as in the kernel. Each native test is
// a fresh `lua` process, so what one script changes must not reach the next
// (#2384): a new global, a rebound base global, and a replaced field of a
// standard-library table.

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/lua-grading-shared.js');
const Lua = globalThis.ChickadeeLuaGradingShared;

const LUA = ['lua', 'lua5.4', 'lua5.3'].find(
    (name) => spawnSync(name, ['-v'], { stdio: 'ignore' }).status === 0);

/// Writes `scripts` into a fresh directory, installs the harness, then runs
/// each script through `_ck.run` in ONE Lua state. Returns the combined stdout.
function runInOneState(scripts) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ck-lua-reset-'));
    for (const [name, source] of Object.entries(scripts)) {
        fs.writeFileSync(path.join(dir, name), source);
    }
    assert.ok(!Lua.SETUP_LUA.includes(']====]'), 'the harness must not close the driver bracket');
    const driver = [
        'local setup = assert(load([====[\n' + Lua.SETUP_LUA + '\n]====], "setup", "t"))',
        'setup()',
    ].concat(Object.keys(scripts).map((name, i) => Lua.runScriptLua(name, 'nonce' + i))).join('\n');
    fs.writeFileSync(path.join(dir, 'driver.lua'), driver);
    return execFileSync(LUA, ['driver.lua'], { cwd: dir, encoding: 'utf8' });
}

test('a script does not see what the previous script changed (#2384)', { skip: !LUA }, () => {
    const stdout = runInOneState({
        'leak.lua': [
            'leaked_global = "yes"',
            'tostring = function() return "tampered" end',
            'string.upper = function() return "tampered" end',
            'math.leaked_field = 1',
        ].join('\n'),
        'check.lua': [
            'print("global=" .. type(rawget(_G, "leaked_global")))',
            'print("tostring=" .. tostring(12))',
            'print("upper=" .. string.upper("ok") .. "," .. ("ok"):upper())',
            'print("field=" .. type(math.leaked_field))',
        ].join('\n'),
    });
    assert.match(stdout, /global=nil/);
    assert.match(stdout, /tostring=12/);
    assert.match(stdout, /upper=OK,OK/);
    assert.match(stdout, /field=nil/);
    assert.match(stdout, /nonce1:status:0/);
});

test('the harness keeps its own process contract across the reset', { skip: !LUA }, () => {
    const stdout = runInOneState({
        'one.lua': 'print("one")',
        'two.lua': 'print("arg0=" .. arg[0]); os.exit(3)',
    });
    assert.match(stdout, /nonce0:status:0/);
    assert.match(stdout, /arg0=two\.lua/);
    assert.match(stdout, /nonce1:status:3/);
});
