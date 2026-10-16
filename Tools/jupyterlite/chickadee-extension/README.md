# @chickadee/jupyterlite-extension

Chickadee's part of the embedded JupyterLite editor (notebook views, NB2):

- the "Chickadee" and "Chickadee dark" themes (`style/index.css`);
- the commands that the notebook page calls through the
  jupyter-iframe-commands bridge: `chickadee:set-theme`, `chickadee:configure`,
  `chickadee:set-guide`, `chickadee:set-suite` and `chickadee:reveal`;
- the events that it posts to the page: `ck:kernel`, `ck:active-cell` and
  `ck:cell-ran`.

The contract is in `docs/notebook-editor-extension.md`.

## Build

The labextension in `chickadee_jupyterlite_extension/labextension/` is built
and committed, so `pip install` needs no Node.js. After a change to `src/` or
`style/`, rebuild it with JupyterLab 4.6.4 on the path:

```
pip install jupyterlab==4.6.4
jlpm install
jlpm build
jlpm test
```

Then copy the new labextension into the bundle:

```
scripts/vendor-chickadee-extension.sh
```
