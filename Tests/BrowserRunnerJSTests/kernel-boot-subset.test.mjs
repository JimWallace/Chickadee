import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Unit coverage for the subset-boot / on-demand-install mechanism in
// Public/xeus-kernel-shared.js.
//
// What this can prove: that the boot seeds resolve, against the REAL vendored
// manifest, to a set that starts a kernel and excludes the data-science half —
// and that every importable name can be resolved back to an installable
// package, which is what the failure-driven path needs to work at all. Those
// are properties of the shipped bytes, so they are worth pinning here where
// they cost milliseconds.
//
// What it cannot prove: that installing into a live kernel works. Only a real
// kernel shows that, and Tools/browser-grading-smoke does it — booting a strict
// subset, asserting numpy is genuinely absent, then asserting it imports and
// computes after the on-demand install.

const ENV_DIR = 'Public/jupyterlite/xeus/chickadee-python';

const kernelSource = await fs.readFile(path.resolve('Public/xeus-kernel-shared.js'), 'utf8');
const pythonSource = await fs.readFile(path.resolve('Public/python-grading-shared.js'), 'utf8');

// The module binds postMessage at load to divert kernel traffic; nothing else
// it touches at load time exists outside a worker.
const context = { console, postMessage: () => {} };
context.self = context;
context.globalThis = context;
const vmContext = vm.createContext(context);
vm.runInContext(kernelSource, vmContext, { filename: 'xeus-kernel-shared.js' });
vm.runInContext(pythonSource, vmContext, { filename: 'python-grading-shared.js' });
const kernel = context.ChickadeeXeusKernel;
const python = context.ChickadeePythonGradingShared;

const meta = JSON.parse(await fs.readFile(path.resolve(ENV_DIR, 'empack_env_meta.json'), 'utf8'));
const index = JSON.parse(await fs.readFile(path.resolve(ENV_DIR, 'importable-modules.json'), 'utf8'));

test('the boot seeds resolve to a runnable kernel', () => {
  const booted = kernel.packageClosure(meta, python.PYTHON_KERNEL.bootSeeds);
  // Without these there is no interpreter to start and no kernel to drive.
  for (const required of ['xeus-python', 'python', 'python_abi', 'xeus']) {
    assert.ok(booted.includes(required), `boot subset is missing ${required}`);
  }
});

test('the boot seeds exclude the data-science half, which is the point', () => {
  const booted = new Set(kernel.packageClosure(meta, python.PYTHON_KERNEL.bootSeeds));
  // These are 84% of the environment by size and most of its install time. If
  // one creeps into the kernel's own dependency closure the saving silently
  // evaporates, and nothing else would notice.
  for (const optional of ['numpy', 'pandas', 'matplotlib-base', 'scipy', 'statsmodels', 'openblas']) {
    assert.ok(!booted.has(optional), `${optional} is in the boot subset; it should load on demand`);
  }
  assert.ok(booted.length !== meta.packages.length);
});

test('each optional package can still be reached from the manifest', () => {
  // The other half: on-demand install walks the same closure, so a package the
  // walk cannot reach could never be installed after boot.
  for (const optional of ['numpy', 'pandas', 'matplotlib-base', 'scipy', 'statsmodels', 'pillow']) {
    const reachable = kernel.packageClosure(meta, [optional]);
    assert.ok(reachable.includes(optional), `${optional} is not reachable from the manifest`);
  }
});

test('scipy drags openblas in, which is why it is not booted by default', () => {
  // Documents the measured cost that motivates the whole subset: openblas is
  // 16 MB, only scipy needs it, and numpy does not.
  assert.ok(kernel.packageClosure(meta, ['scipy']).includes('openblas'));
  assert.ok(!kernel.packageClosure(meta, ['numpy']).includes('openblas'));
});

test('every importable module resolves to a package the environment ships', () => {
  // This is what turns `ModuleNotFoundError: No module named 'X'` back into
  // something installable. A module with no owner is a module the grader could
  // never load on demand.
  const packages = new Set(meta.packages.map(p => p.name));
  for (const moduleName of index.modules) {
    const owner = index.moduleOwners[moduleName];
    assert.ok(owner, `no owning package recorded for module ${moduleName}`);
    assert.ok(packages.has(owner), `module ${moduleName} maps to ${owner}, which is not in the env`);
  }
});

test('import names map to the package that ships them, not the distribution name', () => {
  // The two cases where they differ, and where a hand-maintained table would
  // get it wrong. Deriving from the tarballs is what makes these fall out.
  assert.equal(index.moduleOwners.PIL, 'pillow');
  assert.equal(index.moduleOwners.matplotlib, 'matplotlib-base');
});
