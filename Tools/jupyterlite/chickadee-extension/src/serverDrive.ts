// The server-backed drive (spike for #469).
//
// JupyterLite's default drive keeps every file in the browser's IndexedDB, so a
// student's work in progress reaches the server only at Submit. This plugin
// replaces that drive with JupyterLab's own REST `Drive`, which speaks the
// Jupyter Server contents API: `GET` and `PUT /jupyterlite/api/contents/<path>`
// and the checkpoint calls, served by `JupyterLiteContentsRoutes`. The editor's
// saves, and the kernel's file reads (the main thread answers those through the
// same contents manager, on both the SharedArrayBuffer and the service-worker
// transport), then go to the server.
//
// It is off unless the served `jupyter-lite.json` carries
// `chickadeeServerDrive: "true"`, which `JupyterLiteConfigFlagMiddleware`
// adds only for a request with the `ck_server_drive=1` cookie. With the flag
// off the plugin is not registered at all, so the lite default drive is used
// exactly as before.

import { PageConfig } from '@jupyterlab/coreutils';
import { Contents, Drive, IDefaultDrive, ServerConnection, ServiceManagerPlugin } from '@jupyterlab/services';

/** The page-config option that turns the server drive on. */
export const SERVER_DRIVE_OPTION = 'chickadeeServerDrive';

/** True when the served config asks for the server drive. */
export function serverDriveEnabled(): boolean {
  return PageConfig.getOption(SERVER_DRIVE_OPTION) === 'true';
}

/**
 * The CSRF token of the page that holds the editor frame. The frame is
 * same-origin with the notebook page, whose layout carries the token in
 * `<meta name="csrf-token">`; `CSRFMiddleware` accepts it as `x-csrf-token`.
 */
function parentCsrfToken(): string {
  try {
    const meta = window.parent.document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]');
    return meta?.content ?? '';
  } catch {
    return '';
  }
}

export const serverDrivePlugin: ServiceManagerPlugin<Contents.IDrive> = {
  id: '@chickadee/jupyterlite-extension:server-drive',
  description: 'Saves notebooks to the Chickadee server instead of the browser (spike, #469).',
  autoStart: true,
  provides: IDefaultDrive,
  activate: (): Contents.IDrive => {
    // The token is read on every request, not once: the page can be
    // re-rendered (and its token re-minted) while the editor stays open.
    const withCsrf = (input: RequestInfo, init?: RequestInit): Promise<Response> => {
      const request = new Request(input, init);
      request.headers.set('x-csrf-token', parentCsrfToken());
      return window.fetch(request);
    };
    const serverSettings = ServerConnection.makeSettings({
      init: { cache: 'no-store', credentials: 'same-origin' },
      fetch: withCsrf
    });
    console.info('[chickadee] server drive active', serverSettings.baseUrl);
    return new Drive({ serverSettings });
  }
};
