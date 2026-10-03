// The eight kernel worker files, loaded as a worker loads them and driven
// through their message protocols against a fake kernel (#1963).
//
// Each worker is a config handed to `serveGradingWorker` or `serveEvalWorker`
// in Public/xeus-kernel-shared.js. The drivers call the kernel through the
// object that file exports, so this test replaces `boot`, `execute` and
// `mountWorkspace` on it and keeps the real on-demand install loop. What it
// proves: the init sequence and the order of the setup cells, that a failed
// setup cell (the seed included) fails the init, which stderr a result
// carries, the substrate error when a wrapper never reports, and the
// auto-compute replies.
//
// What it cannot prove: that a real kernel runs these cells. Only a real kernel
// shows that, and Tools/browser-grading-smoke boots all four.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const PUBLIC = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Public');
const SEED = 'deadbeef';
const NONCE = /[0-9a-f]{32}/;

/// Loads `workerFile` the way a browser worker does. `importScripts` reads the
/// file from Public/, except the vendored bootstrap, which only a real kernel
/// needs. Returns the worker's context and every message it posted.
function loadWorker(workerFile) {
    const posted = [];
    const context = {
        console,
        crypto: globalThis.crypto,
        location: { search: '?v=test' },
        postMessage: (message) => { posted.push(message); },
    };
    context.self = context;
    context.globalThis = context;
    const vmContext = vm.createContext(context);
    context.importScripts = (url) => {
        const file = url.split('?')[0];
        if (file.startsWith('/vendor/')) return;
        vm.runInContext(fs.readFileSync(path.join(PUBLIC, file), 'utf8'), vmContext,
            { filename: file });
    };
    vm.runInContext(fs.readFileSync(path.join(PUBLIC, workerFile), 'utf8'), vmContext,
        { filename: workerFile });
    return { context, posted };
}

/// Replaces the kernel's boot, execute and mountWorkspace with fakes that log
/// each call. `respond(code)` answers an execute; omitted fields default to
/// an empty, successful reply.
function fakeKernel(context, respond) {
    const calls = [];
    const kernel = context.ChickadeeXeusKernel;
    kernel.boot = async (spec, options) => {
        calls.push({ boot: spec.kernelName, seeds: options ? options.seeds : 'none' });
    };
    kernel.mountWorkspace = (dir, files, writeFiles) => {
        calls.push({ mount: dir, files, writer: typeof writeFiles });
    };
    kernel.execute = async (code, options) => {
        calls.push({ execute: code, maxWaitMs: options ? options.maxWaitMs : undefined });
        return { stdout: '', stderr: '', failure: null, ...(respond(code) || {}) };
    };
    return calls;
}

/// Sends one message and returns what the worker posted for it, copied out of
/// the worker's realm so the assertions compare plain values.
async function send(worker, message) {
    const before = worker.posted.length;
    await worker.context.onmessage({ data: message });
    return JSON.parse(JSON.stringify(worker.posted.slice(before)));
}

const executed = (calls) => calls.filter((c) => 'execute' in c).map((c) => c.execute);

// --- The grading workers ---------------------------------------------------

const SCRIPT = 'publictest_one';

const GRADERS = [
    {
        file: 'python-grading-worker.js', label: 'Python', prefix: 'python',
        module: 'ChickadeePythonGradingShared', kernelName: 'xpython', script: SCRIPT + '.py',
        setup: (c, dir) => [
            c.ChickadeeGradingShared.assignmentSeedPython(SEED),
            c.ChickadeePythonGradingShared.cleanStateCellPython(dir),
            c.ChickadeeGradingShared.envConfigPython(dir),
        ],
        // The cell captures its own stderr, so the payload's wins over the
        // kernel stream's.
        output: (nonce) => '\n' + nonce + ':' + JSON.stringify(
            { exit: 1, out: 'hello\n', err: 'own stderr', error: null }) + '\n',
        expected: { exitCode: 1, stdout: 'hello\n', stderr: 'own stderr' },
    },
    {
        file: 'r-grading-worker.js', label: 'R', prefix: 'r',
        module: 'ChickadeeRGradingShared', kernelName: 'xr', script: SCRIPT + '.R',
        setup: (c) => [c.ChickadeeRGradingShared.assignmentSeedR(SEED)],
        output: (nonce) => '\n' + nonce + ':status:1\nhello\n' + nonce + ':end\n',
        expected: { exitCode: 1, stdout: 'hello', stderr: 'kernel stderr' },
    },
    {
        file: 'lua-grading-worker.js', label: 'Lua', prefix: 'lua',
        module: 'ChickadeeLuaGradingShared', kernelName: 'xlua', script: SCRIPT + '.lua',
        setup: (c) => [
            c.ChickadeeLuaGradingShared.SETUP_LUA,
            c.ChickadeeLuaGradingShared.assignmentSeedLua(SEED),
        ],
        output: (nonce) => 'hello\n\n' + nonce + ':status:1\n',
        expected: { exitCode: 1, stdout: 'hello\n', stderr: 'kernel stderr' },
    },
    {
        file: 'octave-grading-worker.js', label: 'Octave', prefix: 'octave',
        module: 'ChickadeeOctaveGradingShared', kernelName: 'xoctave', script: SCRIPT + '.m',
        setup: (c) => [
            c.ChickadeeOctaveGradingShared.SETUP_OCTAVE,
            c.ChickadeeOctaveGradingShared.assignmentSeedOctave(SEED),
        ],
        output: (nonce) => 'hello\n\n' + nonce + ':status:1\n',
        expected: { exitCode: 1, stdout: 'hello\n', stderr: 'kernel stderr' },
    },
];

for (const grader of GRADERS) {
    test(`${grader.file}: init boots, mounts, then runs every setup cell in order`, async () => {
        const worker = loadWorker(grader.file);
        const calls = fakeKernel(worker.context, () => null);
        const replies = await send(worker,
            { id: 1, type: 'init', files: { 'a.txt': 'x' }, seed: SEED });

        const spec = worker.context[grader.module];
        const kernelSpec = Object.values(spec).find((v) => v && v.kernelName === grader.kernelName);
        assert.deepEqual(calls[0], { boot: grader.kernelName, seeds: kernelSpec.bootSeeds });
        assert.match(calls[1].mount, /^\/chickadee_work_\d+$/);
        assert.deepEqual(calls[1].files, { 'a.txt': 'x' });
        assert.equal(calls[1].writer, 'function');
        assert.deepEqual(executed(calls), grader.setup(worker.context, calls[1].mount));

        assert.deepEqual(replies.map((r) => r.phase || r.id),
            [`${grader.prefix}_kernel_booted`, `${grader.prefix}_env_configured`, 1]);
        assert.deepEqual(replies[2], { id: 1, ok: true });
    });

    test(`${grader.file}: no seed means no seed cell`, async () => {
        const worker = loadWorker(grader.file);
        const calls = fakeKernel(worker.context, () => null);
        await send(worker, { id: 1, type: 'init', files: {}, seed: null });
        const expected = grader.setup(worker.context, calls[1].mount)
            .filter((cell) => !cell.includes(SEED));
        assert.deepEqual(executed(calls), expected);
    });

    test(`${grader.file}: a seed cell that fails fails the init`, async () => {
        const worker = loadWorker(grader.file);
        fakeKernel(worker.context, (code) => (code.includes(SEED) ? { failure: 'Error: no setenv' } : null));
        const replies = await send(worker, { id: 7, type: 'init', files: {}, seed: SEED });
        const last = replies[replies.length - 1];
        assert.equal(last.id, 7);
        assert.equal(last.ok, false);
        assert.equal(last.error,
            `the ${grader.label} kernel did not set the assignment seed: Error: no setenv`);
        assert.ok(!replies.some((r) => r.phase === `${grader.prefix}_env_configured`));
    });

    test(`${grader.file}: run returns the wrapper's exit code, stdout and stderr`, async () => {
        const worker = loadWorker(grader.file);
        fakeKernel(worker.context, (code) => {
            if (!code.includes(grader.script)) return null;
            return { stdout: grader.output(code.match(NONCE)[0]), stderr: 'kernel stderr' };
        });
        await send(worker, { id: 1, type: 'init', files: {}, seed: null });
        const replies = await send(worker, { id: 2, type: 'run', script: grader.script, limit: 10 });
        assert.deepEqual(replies, [{ id: 2, ok: true, result: grader.expected }]);
    });

    test(`${grader.file}: a wrapper that never reports is a substrate error`, async () => {
        const worker = loadWorker(grader.file);
        fakeKernel(worker.context, (code) => (code.includes(grader.script)
            ? { stderr: 'trace', failure: 'RuntimeError: died' } : null));
        await send(worker, { id: 1, type: 'init', files: {}, seed: null });
        const replies = await send(worker, { id: 2, type: 'run', script: grader.script, limit: 10 });
        assert.deepEqual(replies, [{
            id: 2, ok: true,
            result: {
                exitCode: 2,
                stdout: `${grader.label} grading failed: RuntimeError: died`,
                stderr: 'trace',
            },
        }]);
    });

    test(`${grader.file}: an unknown message type is an error reply`, async () => {
        const worker = loadWorker(grader.file);
        fakeKernel(worker.context, () => null);
        const replies = await send(worker, { id: 3, type: 'nope' });
        assert.deepEqual(replies, [{ id: 3, ok: false, error: 'unknown message type: nope' }]);
    });
}

test('python-grading-worker.js: each script starts with the reset, then the environment config', async () => {
    const worker = loadWorker('python-grading-worker.js');
    const calls = fakeKernel(worker.context, () => null);
    await send(worker, { id: 1, type: 'init', files: {}, seed: null });
    const dir = calls[1].mount;
    const before = executed(calls).length;
    await send(worker, { id: 2, type: 'run', script: 'publictest_one.py', limit: 10 });
    const run = executed(calls).slice(before);
    const python = worker.context.ChickadeePythonGradingShared;
    assert.equal(run[0],
        python.RESET_CELL_PYTHON + '\n' + worker.context.ChickadeeGradingShared.envConfigPython(dir));
    assert.ok(run[1].includes('publictest_one.py'));
    assert.equal(run.length, 2);
});

test('python-grading-worker.js: a reset that fails is a substrate error, and the script never runs', async () => {
    const worker = loadWorker('python-grading-worker.js');
    const python = () => worker.context.ChickadeePythonGradingShared;
    const calls = fakeKernel(worker.context, (code) => (code.startsWith(python().RESET_CELL_PYTHON)
        ? { failure: 'NameError: _ck_reset' } : null));
    await send(worker, { id: 1, type: 'init', files: {}, seed: null });
    const replies = await send(worker, { id: 2, type: 'run', script: 'publictest_one.py', limit: 10 });
    assert.equal(replies[0].result.exitCode, 2);
    assert.equal(replies[0].result.stdout, 'Python grading failed: NameError: _ck_reset');
    assert.ok(!executed(calls).some((code) => code.includes('publictest_one.py')));
});

// --- The auto-compute workers ----------------------------------------------

const RUNTIME = 'RUNTIME_SOURCE';

const EVALUATORS = [
    {
        file: 'python-eval-worker.js', label: 'Python', kernelName: 'xpython', maxWaitMs: 60000,
        // Python defines no seeded runtime and builds call snippets on the
        // main thread.
        bootCell: null, call: false,
    },
    {
        file: 'r-eval-worker.js', label: 'R', kernelName: 'xr', maxWaitMs: 60000,
        bootCell: () => RUNTIME, call: true,
    },
    {
        file: 'lua-eval-worker.js', label: 'Lua', kernelName: 'xlua', maxWaitMs: 60000,
        bootCell: (c) => c.ChickadeeLuaEvalShared.bootCell(RUNTIME), call: true,
    },
    {
        file: 'octave-eval-worker.js', label: 'Octave', kernelName: 'xoctave', maxWaitMs: 90000,
        bootCell: (c) => c.ChickadeeOctaveEvalShared.bootCell(RUNTIME), call: true,
    },
];

/// The payload a snippet prints behind its nonce.
const payload = (code, body) => ({ stdout: '\n' + code.match(NONCE)[0] + ':' + JSON.stringify(body) + '\n' });

for (const evaluator of EVALUATORS) {
    test(`${evaluator.file}: init boots the whole env once and defines the runtime`, async () => {
        const worker = loadWorker(evaluator.file);
        const calls = fakeKernel(worker.context, () => null);
        assert.deepEqual(await send(worker, { id: 1, type: 'init', runtimeSource: RUNTIME }),
            [{ id: 1, ok: true }]);
        await send(worker, { id: 2, type: 'init', runtimeSource: RUNTIME });

        assert.deepEqual(calls[0], { boot: evaluator.kernelName, seeds: 'none' });
        assert.equal(calls.filter((c) => 'boot' in c).length, 1);
        const expected = evaluator.bootCell ? [evaluator.bootCell(worker.context)] : [];
        assert.deepEqual(executed(calls), expected);
        for (const call of calls.filter((c) => 'execute' in c)) {
            assert.equal(call.maxWaitMs, evaluator.maxWaitMs);
        }
    });

    if (evaluator.bootCell) {
        test(`${evaluator.file}: a runtime that fails to define fails the init`, async () => {
            const worker = loadWorker(evaluator.file);
            fakeKernel(worker.context, () => ({ failure: 'Error: boom' }));
            assert.deepEqual(await send(worker, { id: 1, type: 'init', runtimeSource: RUNTIME }), [{
                id: 1, ok: false,
                error: `the ${evaluator.label} auto-compute runtime failed to load: Error: boom`,
            }]);
        });
    }

    test(`${evaluator.file}: loadCells reports each cell's error and keeps going`, async () => {
        const worker = loadWorker(evaluator.file);
        fakeKernel(worker.context, (code) => {
            if (code.includes('CELL_A')) return payload(code, { value: null, error: 'bad cell' });
            if (code.includes('CELL_B')) return payload(code, { value: null, error: null });
            if (code.includes('CELL_C')) return { stderr: '  lost  ', failure: null };
            return null;
        });
        const replies = await send(worker,
            { id: 1, type: 'loadCells', cells: ['CELL_A', 'CELL_B', 'CELL_C'] });
        assert.deepEqual(replies, [{
            id: 1, ok: true,
            cellErrors: [{ index: 0, message: 'bad cell' }, { index: 2, message: 'lost' }],
        }]);
    });

    test(`${evaluator.file}: run returns the value, or the snippet's error`, async () => {
        const worker = loadWorker(evaluator.file);
        fakeKernel(worker.context, (code) => {
            if (code.includes('GOOD')) return payload(code, { value: '42', error: null });
            if (code.includes('BAD')) return payload(code, { value: null, error: 'no such name' });
            if (code.includes('DEAD')) return { failure: null };
            return null;
        });
        assert.deepEqual(await send(worker, { id: 1, type: 'run', code: 'GOOD' }),
            [{ id: 1, ok: true, result: '42' }]);
        assert.deepEqual(await send(worker, { id: 2, type: 'run', code: 'BAD' }),
            [{ id: 2, ok: false, error: 'no such name' }]);
        assert.deepEqual(await send(worker, { id: 3, type: 'run', code: 'DEAD' }),
            [{ id: 3, ok: false, error: `the ${evaluator.label} kernel produced no result` }]);
    });

    test(`${evaluator.file}: call is served ${evaluator.call ? '' : 'nowhere but the main thread'}`.trim(), async () => {
        const worker = loadWorker(evaluator.file);
        fakeKernel(worker.context, (code) => (code.includes('solve') ? payload(code, { value: '7', error: null }) : null));
        const replies = await send(worker,
            { id: 1, type: 'call', functionName: 'solve', args: [1, 2], captureStdout: false });
        assert.deepEqual(replies, evaluator.call
            ? [{ id: 1, ok: true, result: '7' }]
            : [{ id: 1, ok: false, error: 'unknown message type: call' }]);
    });
}
