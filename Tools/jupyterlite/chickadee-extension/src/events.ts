// The events the extension posts up to the notebook page. They use the same
// channel as jl-kernel-diagnostics.js: `window.parent.postMessage` to this
// origin, with a `ck` field that names the message. The page accepts only
// same-origin messages with a `ck` it knows.
//
//   ck:kernel       { status: 'starting' | 'idle' | 'busy' | 'dead' }
//   ck:notebook-open {}, once the notebook's cells are drawn
//   ck:active-cell  { cellId, index, names }
//   ck:cell-ran     { cellId, status: 'ok' | 'error' }
//   ck:saved        { state: 'started' | 'completed' | 'failed' }, which the
//                   toolbar's save state reads

export type KernelState = 'starting' | 'idle' | 'busy' | 'dead';

/** Maps a session's kernel status onto the four states the toolbar shows. */
export function kernelState(status: string): KernelState {
  switch (status) {
    case 'idle':
      return 'idle';
    case 'busy':
      return 'busy';
    case 'dead':
    case 'terminating':
      return 'dead';
    default:
      // unknown, starting, restarting, autorestarting
      return 'starting';
  }
}

/** Posts one event to the page. Never throws. */
export function post(message: { ck: string; [key: string]: unknown }): void {
  try {
    window.parent.postMessage(message, window.location.origin);
  } catch {
    // The page may be gone; an event is never worth an error.
  }
}
