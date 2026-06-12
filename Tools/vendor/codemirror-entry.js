// Single entry point for Chickadee's CodeMirror usage.
//
// Bundled into Public/vendor/codemirror.js by scripts/setup-vendor.sh.
// The Leaf templates import this bundle and pluck named exports they
// need.  Adding a new CodeMirror import: extend this file with the
// re-export, then re-run the setup script.

export {
    EditorView,
    keymap,
    lineNumbers,
    highlightActiveLine,
    drawSelection,
    dropCursor,
} from "@codemirror/view";

export { EditorState, Compartment } from "@codemirror/state";

export {
    defaultKeymap,
    history,
    historyKeymap,
    indentWithTab,
} from "@codemirror/commands";

export {
    syntaxHighlighting,
    defaultHighlightStyle,
    StreamLanguage,
} from "@codemirror/language";

export { python } from "@codemirror/lang-python";
export { shell } from "@codemirror/legacy-modes/mode/shell";
export { r } from "@codemirror/legacy-modes/mode/r";
