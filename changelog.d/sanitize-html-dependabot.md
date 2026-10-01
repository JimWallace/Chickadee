### Security

- **`sanitize-html` raised to 2.18.0 in the vendor build tool.** Dependabot alert 7: `Tools/vendor/package-lock.json` resolved it to 2.12.1, which carries two moderate advisories, through `jupyter-iframe-commands-host` and JupyterLab's apputils. The copy existed only in the build tool's `node_modules`; no file under `Public/vendor/` contains it, so nothing served to a browser changes. An `overrides` entry pins the fixed release and `npm audit` reports zero findings across all five lockfiles. Closes #1701.
