### Fixed

- **The runner image has the tidyverse core.** The xeus-r browser kernel ships dplyr, tidyr, readr, stringr, tibble, purrr and forcats, but the runner image had only base R, so a worker-graded R test that loaded one of them failed on the worker after passing in the browser. The image now installs them as Debian binary packages (`r-cran-*`, so nothing compiles from CRAN), and the image build checks that `Rscript` can load each of them.
