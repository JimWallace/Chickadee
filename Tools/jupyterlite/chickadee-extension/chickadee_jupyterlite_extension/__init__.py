"""Chickadee's JupyterLite extension. The labextension is prebuilt."""


def _jupyter_labextension_paths():
    return [{"src": "labextension", "dest": "@chickadee/jupyterlite-extension"}]
