### Changed

- **Re-vendored the xeus kernel bundle.** The weekly kernel-currency check
  found the browser Python environment behind its channel. This rebuild moves
  `pandas` from 3.0.5 to 3.0.6, `wcwidth` from 0.8.3 to 0.8.4 and `pyparsing`
  from 3.3.2 to 3.3.3. The Lua, R and Octave environments solve to the packages
  they already had. No kernel moves: all four stay on xeus 6.0.5, and each
  kernel is already at the newest version its channel offers.
