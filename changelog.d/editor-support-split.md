### Changed

- **`LanguageDescriptor` can now express a language with no editor kernel.**
  The four descriptor facts that presupposed a vendored JupyterLite kernel
  (the environment file, kernel name, display label, and missing-dependency
  wording) are folded behind one `editorSupport` judgement:
  `.notebookKernel(...)` for every current language, `.uploadOnly` for a
  compiled language graded through the shell-script + makefile path whose
  submissions arrive as file uploads. Purely internal — every language keeps
  its kernel and every behaviour is unchanged — but a kernel-less language is
  now expressible at all, which the compiled-C++ arc requires, and a test pins
  that admitting one is a deliberate, stated decision rather than an
  unfinished descriptor.
