// Shared loader for the vendored RunnerCore wasm (Public/runner-wasm/).
//
// The wasm filename is content-hashed (RunnerWasm.<hash>.wasm) for immutable
// caching, so it is discovered rather than named. The module is compiled and
// initialised once per test process; every caller shares that one instance.

import fs from 'node:fs/promises';
import path from 'node:path';

const RUNNER_DIR = path.resolve('Public/runner-wasm');

let ready;

/** Resolves with what `init()` returns: `{ exports, ... }`. */
export function loadRunnerWasm() {
  if (!ready) {
    ready = (async () => {
      const { init } = await import(path.join(RUNNER_DIR, 'runner-core.js'));
      const wasmName = (await fs.readdir(RUNNER_DIR)).find(f => /^RunnerWasm\..*\.wasm$/.test(f));
      if (!wasmName) throw new Error(`no RunnerWasm.<hash>.wasm in ${RUNNER_DIR}`);
      const module = await WebAssembly.compile(await fs.readFile(path.join(RUNNER_DIR, wasmName)));
      return init({ module });
    })();
  }
  return ready;
}
