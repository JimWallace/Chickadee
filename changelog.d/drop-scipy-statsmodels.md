### Removed

- **scipy and statsmodels are no longer in the browser Python kernel.** They,
  and `openblas`, `patsy` and `six`, which only they needed, were about 27 MB of
  a ~69 MB environment, roughly 40% of every Python kernel boot, and no course
  needed them in the browser. A browser-graded test that imports either one is
  now refused when it is saved, and a student notebook that imports one gets
  `ModuleNotFoundError` in the editor. Worker-graded assignments are unaffected:
  they run on the runner's own Python. #3122 revisits the decision before the
  next minor.
