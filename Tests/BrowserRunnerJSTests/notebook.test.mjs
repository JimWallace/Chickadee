import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const notebookSource = await fs.readFile(
  path.resolve('Public/notebook.js'),
  'utf8',
);

async function loadNotebookHarness() {
  const hooks = {};
  const elements = new Map();

  const frame = {
    dataset: {
      setupId: 'setup_123',
      gradingMode: 'browser',
      notebookUrl: '/api/v1/testsetups/setup_123/assignment',
      editorUrl: '/jupyterlite/notebooks/index.html?path=assignment.ipynb',
    },
    addEventListener() {},
    getAttribute(name) {
      return name === 'src' ? this.dataset.editorUrl : null;
    },
    contentWindow: null,
    contentDocument: null,
    src: '',
  };

  elements.set('jl-frame', frame);
  elements.set('nb-status', { textContent: '', className: '' });
  elements.set('nb-results', { hidden: true, innerHTML: '', appendChild() {}, scrollIntoView() {} });
  elements.set('nb-frame-error', { style: { display: 'none' } });

  const document = {
    getElementById(id) {
      return elements.get(id) ?? null;
    },
    createElement() {
      return {
        className: '',
        textContent: '',
        innerHTML: '',
        appendChild() {},
      };
    },
    head: { appendChild() {} },
  };

  const fetch = async () => ({ ok: true, async json() { return { cells: [] }; } });

  const context = {
    console,
    document,
    fetch,
    setTimeout,
    clearTimeout,
    setInterval: () => 1,
    clearInterval: () => {},
    URL,
    JSON,
    Error,
    Promise,
    window: { location: { origin: 'https://example.test' } },
    __CHICKADEE_NOTEBOOK_TEST_HOOKS__: hooks,
  };
  context.globalThis = context;

  vm.runInNewContext(notebookSource, context, { filename: 'notebook.js' });
  return hooks.exports;
}

test('notebook formatting uses human-readable labels and traceback-only details', async () => {
  const notebook = await loadNotebookHarness();
  const outcome = {
    testName: 'test_q1_bmi',
    scriptName: 'test_q1_bmi.py',
    displayName: 'Q1: BMI Calculation',
    tier: 'public',
    status: 'error',
    shortResult: '{"shortResult":"Q1: BMI Calculation: Could not test calculate_bmi","status":"error","error":"Could not test calculate_bmi","traceback":"Traceback (most recent call last):\\n  File \\"test_q1_bmi.py\\", line 12, in <module>\\n    result = fn(*args)\\nNotImplementedError: Implement calculate_bmi\\n"}',
    longResult: 'stdout:\n{"shortResult":"Q1: BMI Calculation: Could not test calculate_bmi","status":"error","error":"Could not test calculate_bmi","traceback":"Traceback (most recent call last):\\n  File \\"test_q1_bmi.py\\", line 12, in <module>\\n    result = fn(*args)\\nNotImplementedError: Implement calculate_bmi\\n"}',
  };

  assert.equal(notebook.bestOutcomeDisplayName(outcome), 'Q1: BMI Calculation');
  assert.equal(notebook.formattedOutcomeShortResult(outcome), 'Could not test calculate_bmi');
  assert.equal(
    notebook.formattedOutcomeDetailedOutput(outcome),
    'Traceback (most recent call last):\n  File "test_q1_bmi.py", line 12, in <module>\n    result = fn(*args)\nNotImplementedError: Implement calculate_bmi'
  );

  const displayMap = notebook.buildOutcomeDisplayNameMap([outcome]);
  assert.equal(displayMap.get('test_q1_bmi'), 'Q1: BMI Calculation');
  assert.equal(displayMap.get('test_q1_bmi.py'), 'Q1: BMI Calculation');
});
