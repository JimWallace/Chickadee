### Fixed

- **Worker-graded R notebook submissions now grade.** The runner's submission
  router (`shouldNormalizePythonSubmission`) treated every `.ipynb` as Python, so
  an R-kernel notebook was extracted as `solution.py` and never produced the
  `solution.R` the R tests source — every test errored with "No R submission file
  was found to grade." R-kernel notebooks (`ir`/`r`/`webr`/`xr`, or
  `language_info.name == "r"`) in a pure-R setup now route to the R extractor and
  produce `solution.R`. Python and mixed assignments are unchanged.
