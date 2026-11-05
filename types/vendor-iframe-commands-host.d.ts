// Type declarations for `tsc -p jsconfig.json` (#2782). Not served.
//
// Public/vendor/iframe-commands-host.js is a vendored ES-module bundle (the
// host side of jupyter-iframe-commands, with comlink inlined) that has no type
// declarations of its own. Public/notebook.js imports it by its served path,
// `/vendor/iframe-commands-host.js`, so the `paths` entry in jsconfig.json
// maps it to this file, as for vendor-codemirror.d.ts.
//
// The values are `any`, like the globals in chickadee-globals.d.ts. Add a
// name here when a page imports another export from the bundle.
export declare const createBridge: any;
export declare const createProxy: any;
