### Changed

- **C++, Java and Racket personalization expressions get 15 seconds.** The evaluator's limit per evaluation was 5 seconds for every language. It also covers the interpreter's start-up and, for C++ and Java, a compile: on an idle host, one Java evaluation with one support helper takes about 3.5 s, C++ 2.75 s and Racket 1.5 s, so a loaded server could refuse an instructor's preview or a student's first open. Python, R, Lua and Octave keep 5 seconds. The refusal message now states the language's limit (#2001).
