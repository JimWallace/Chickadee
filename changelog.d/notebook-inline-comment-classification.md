### Fixed

- **Inline `#` comments no longer confuse notebook cell classification.** A
  top-level statement like `print(total_dose_mg) #when weight_kg = 30` found
  the `=` inside its trailing comment and was misclassified as a module-level
  assignment, so the `print(...)` ran at import time and leaked stray stdout
  into test `longResult`s. Comments are now stripped (quote-aware, so `#`
  inside string literals is untouched) before classification — which also
  fixes the inverse case where a real assignment whose comment mentioned a
  call (`dose = 30  # see compute()`) was wrongly quarantined. Fixed in
  `RunnerCore`, so the native worker and the browser/wasm grader both pick it
  up. (#741)
