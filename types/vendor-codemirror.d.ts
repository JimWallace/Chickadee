// Type declarations for `tsc -p jsconfig.json` (#2782). Not served.
//
// Public/vendor/codemirror.js is a vendored ES-module bundle of CodeMirror 6
// with no type declarations of its own. Public/test-renderer-script.js
// imports it by its served path, `/vendor/codemirror.js`. tsc reads a rooted
// path as a file-system path and does not match it to a `declare module`, so
// the `paths` entry in jsconfig.json maps it to this module file instead.
//
// Each export a page reads is named here, so a misspelt import is a type
// error. The values are `any`, like the globals in chickadee-globals.d.ts.
// Add a name here when a page imports another export from the bundle.
export declare const EditorView: any;
export declare const keymap: any;
export declare const lineNumbers: any;
export declare const highlightActiveLine: any;
export declare const drawSelection: any;
export declare const dropCursor: any;
export declare const EditorState: any;
export declare const Compartment: any;
export declare const defaultKeymap: any;
export declare const history: any;
export declare const historyKeymap: any;
export declare const indentWithTab: any;
export declare const syntaxHighlighting: any;
export declare const defaultHighlightStyle: any;
export declare const StreamLanguage: any;
export declare const python: any;
export declare const shell: any;
export declare const r: any;
export declare const lua: any;
export declare const octave: any;
export declare const scheme: any;
export declare const java: any;
export declare const cpp: any;
