// The server-backed drive (#469).
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
// It is on when the served `jupyter-lite.json` carries
// `chickadeeServerDrive: "true"`, which `JupyterLiteConfigFlagMiddleware` adds
// for every request except one with the `ck_server_drive=0` cookie, and the
// page's editor frame allows it (`serverDriveEnabled`). Otherwise the plugin is
// not registered at all, so JupyterLite's IndexedDB drive is used as before.

import { PageConfig } from '@jupyterlab/coreutils';
import { Contents, Drive, IDefaultDrive, ServerConnection, ServiceManagerPlugin } from '@jupyterlab/services';

/** The page-config option that turns the server drive on. */
export const SERVER_DRIVE_OPTION = 'chickadeeServerDrive';

/**
 * True when the server drive is on for this editor: the served config asks for
 * it (every browser but one that opted out), and the page's editor frame allows
 * it (`data-server-drive="true"`, which the server renders only on a copy that
 * holds the viewer's own work; a staff authoring copy is rebuilt from the
 * stored notebook on every load, so it stays on IndexedDB). An editor with no
 * such frame, such as the standalone REPL, stays on IndexedDB.
 */
export function serverDriveEnabled(): boolean {
  if (PageConfig.getOption(SERVER_DRIVE_OPTION) !== 'true') {
    return false;
  }
  try {
    const frame = window.frameElement as HTMLElement | null;
    return frame?.dataset.serverDrive === 'true';
  } catch {
    return false;
  }
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
  description: 'Saves notebooks to the Chickadee server instead of the browser (#469).',
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
