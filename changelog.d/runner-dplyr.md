### Fixed

- **The runner image has dplyr.** The xeus-r browser kernel ships dplyr, but the runner image had only base R, so a worker-graded R test that loaded dplyr failed on the worker after passing in the browser. The image now installs `r-cran-dplyr` (the Debian binary package, so nothing compiles from CRAN), and the image build checks that `Rscript` can load it.
