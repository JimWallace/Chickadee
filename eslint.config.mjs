// ESLint config for Chickadee's first-party frontend JavaScript (#1134).
//
// Scope: Public/*.js (served as-is, classic scripts unless noted) and the
// Tests/BrowserRunnerJSTests node test suite.  Vendored/generated trees are
// ignored — we don't lint code we don't author.
//
// This is a correctness gate, not a formatter: eslint:recommended plus the
// shared globals the classic-script files exchange via window.  Zero
// tolerance — scripts/eslint.sh runs with --max-warnings 0, so every finding
// is fixed or carries an explicit eslint-disable comment with a reason.
import js from '@eslint/js';

// Globals the classic scripts share by assignment onto window (defined in
// chickadee-ui.js / grading-shared.js, consumed everywhere).  Keep this list
// short — new cross-file API should hang off ChickadeeUI rather than adding
// names.
const chickadeeGlobals = {
  ChickadeeUI: 'readonly',
  ChickadeeInputsCore: 'readonly',
  ChickadeeGradingShared: 'readonly',
  ChickadeeRGradingShared: 'readonly',
  // Published by the vendored /vendor/xeus-bootstrap.js, importScripts'd by the
  // R grading worker.
  ChickadeeXeusBootstrap: 'readonly',
};

const browserGlobals = {
  window: 'readonly', document: 'readonly', navigator: 'readonly',
  console: 'readonly', fetch: 'readonly', URL: 'readonly',
  URLSearchParams: 'readonly', FormData: 'readonly', Blob: 'readonly',
  File: 'readonly', FileReader: 'readonly', AbortController: 'readonly',
  setTimeout: 'readonly', clearTimeout: 'readonly',
  setInterval: 'readonly', clearInterval: 'readonly',
  localStorage: 'readonly', sessionStorage: 'readonly',
  indexedDB: 'readonly', crypto: 'readonly', performance: 'readonly',
  location: 'readonly', history: 'readonly', alert: 'readonly',
  confirm: 'readonly', CustomEvent: 'readonly', Event: 'readonly',
  Element: 'readonly',
  MutationObserver: 'readonly', requestAnimationFrame: 'readonly',
  Worker: 'readonly', WebSocket: 'readonly', DOMParser: 'readonly',
  TextDecoder: 'readonly', TextEncoder: 'readonly',
  structuredClone: 'readonly', queueMicrotask: 'readonly',
  getComputedStyle: 'readonly', DataTransfer: 'readonly',
  BroadcastChannel: 'readonly', crossOriginIsolated: 'readonly',
  caches: 'readonly', CompressionStream: 'readonly',
  DecompressionStream: 'readonly', Response: 'readonly',
  Request: 'readonly', Headers: 'readonly', ReadableStream: 'readonly',
  loadPyodide: 'readonly', JSZip: 'readonly',
  // Defined by the xeus-r kernel's emscripten glue (bin/xr.js), which the R
  // grading worker pulls in with importScripts — MODULARIZE's EXPORT_NAME.
  createXeusModule: 'readonly',
};

const workerGlobals = {
  self: 'readonly', importScripts: 'readonly', postMessage: 'readonly',
  onmessage: 'writable', close: 'readonly',
};

// Classic scripts that also export for the node test suite via a guarded
// `typeof module !== 'undefined'` block.
const dualEnvGlobals = { module: 'readonly' };

export default [
  {
    ignores: [
      'Public/pyodide/**',
      'Public/jupyterlite/**',
      'Public/vendor/**',
      'Tools/**',
      'node_modules/**',
      '.build/**',
      'reference/**',
    ],
  },
  js.configs.recommended,
  {
    // First-party browser scripts: classic (non-module) unless overridden.
    files: ['Public/*.js'],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'script',
      globals: { ...browserGlobals, ...workerGlobals, ...dualEnvGlobals, ...chickadeeGlobals },
    },
    rules: {
      // catch (e) {} with the error deliberately unused is idiomatic here
      // (fail-safe wrappers around diagnostics); `_`-prefixed args/vars are
      // the explicit "intentionally unused" marker.
      'no-unused-vars': ['error', {
        args: 'after-used',
        argsIgnorePattern: '^_',
        varsIgnorePattern: '^_',
        caughtErrors: 'none',
      }],
      // Empty `catch (e) {}` is the codebase's fail-safe idiom around
      // best-effort work (diagnostics, cache cleanup); empty non-catch
      // blocks still fail.
      'no-empty': ['error', { allowEmptyCatch: true }],
      // The definition files themselves (chickadee-ui.js defines ChickadeeUI)
      // would otherwise collide with the config-declared shared globals.
      // Same-scope var/var redeclarations are still caught.
      'no-redeclare': ['error', { builtinGlobals: false }],
    },
  },
  {
    // ES-module renderers (CodeMirror imports).
    files: ['Public/test-renderer-script.js', 'Public/test-renderer-check.js'],
    languageOptions: { sourceType: 'module' },
  },
  {
    // Node test suite.
    files: ['Tests/BrowserRunnerJSTests/**/*.mjs'],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'module',
      globals: {
        process: 'readonly', console: 'readonly', Buffer: 'readonly',
        URL: 'readonly', TextDecoder: 'readonly', TextEncoder: 'readonly',
        setTimeout: 'readonly', clearTimeout: 'readonly',
        structuredClone: 'readonly', fetch: 'readonly',
        Blob: 'readonly', FormData: 'readonly', WebAssembly: 'readonly',
        __dirname: 'readonly', global: 'writable',
      },
    },
    rules: {
      'no-unused-vars': ['error', {
        args: 'after-used',
        argsIgnorePattern: '^_',
        varsIgnorePattern: '^_',
        caughtErrors: 'none',
      }],
    },
  },
];
