// Unit tests for the results formatting in Public/notebook-core.js, the pure
// half of the notebook page. The core has a node export, so these tests load
// it directly. They do not boot notebook.js under a stub DOM.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const notebook = require('../../Public/notebook-core.js');

test('notebook formatting uses human-readable labels and traceback-only details', () => {
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

test('the notebook page loads the core before notebook.js', async () => {
  const src = await fs.readFile(path.resolve('Resources/Views/_notebook-body.leaf'), 'utf8');
  const core = src.indexOf('/notebook-core.js');
  const wiring = src.indexOf('/notebook.js');
  assert.ok(core >= 0 && wiring >= 0 && core < wiring, 'core must be loaded before notebook.js');
});
