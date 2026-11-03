// Type declarations for `tsc -p jsconfig.json` (#2782). Not served, not loaded
// by a browser: Public/*.js has no build step, and this file only tells the
// type checker which names the classic scripts share at run time.
//
// Each name here is a global that one Public/*.js file publishes (on window,
// self or the IIFE `global` parameter) and another reads. Declaring the names
// one by one, not with an index signature on Window, is the point: a
// misspelt global is then a type error, not an `undefined` at run time.
//
// The values are `any` for now. Typing a module's shape (for example
// ChickadeeUI's functions) is the next step, one module at a time.
//
// Add a name here when you add a cross-file global. Keep the list in sync with
// chickadeeGlobals in eslint.config.mjs where a file reads the bare name.

// Shared modules and page controllers.
declare var BrowserRunner: any;
declare var ChickadeeAccordion: any;
declare var ChickadeeAchievementsCore: any;
declare var ChickadeeAutoCompute: any;
declare var ChickadeeCelebrateCore: any;
declare var ChickadeeCheckRendererCore: any;
declare var ChickadeeCompositeCore: any;
declare var ChickadeeEditPage: any;
declare var ChickadeeEvalProtocol: any;
declare var ChickadeeGraded: any;
declare var ChickadeeGradingExecutors: any;
declare var ChickadeeGradingShared: any;
declare var ChickadeeInputsCore: any;
declare var ChickadeeLanguage: any;
declare var ChickadeeListFilter: any;
declare var ChickadeeLuaEvalShared: any;
declare var ChickadeeLuaGradingShared: any;
declare var ChickadeeNotebookBoot: any;
declare var ChickadeeNotebookCore: any;
declare var ChickadeeNotebookFailures: any;
declare var ChickadeeNotebookGuide: any;
declare var ChickadeeNotebookPreflightCore: any;
declare var ChickadeeNotebookToolbar: any;
declare var ChickadeeOctaveEvalShared: any;
declare var ChickadeeOctaveGradingShared: any;
declare var ChickadeePythonEvalShared: any;
declare var ChickadeePythonGradingShared: any;
declare var ChickadeeQuantumCatsEgg: any;
declare var ChickadeeREvalShared: any;
declare var ChickadeeRGradingShared: any;
declare var ChickadeeRelativeTime: any;
declare var ChickadeeRunnerSupportSources: any;
declare var ChickadeeScriptRendererConfig: any;
declare var ChickadeeScriptRendererCore: any;
declare var ChickadeeSortableTable: any;
declare var ChickadeeSparkline: any;
declare var ChickadeeStarterTestsCore: any;
declare var ChickadeeSurfaceSwap: any;
declare var ChickadeeTablePoll: any;
declare var ChickadeeTestEditorCatalog: any;
declare var ChickadeeTestRenderers: any;
declare var ChickadeeUI: any;
declare var ChickadeeWorkbench: any;
declare var ChickadeeWorkbenchRail: any;
declare var ChickadeeXeusBootstrap: any;
declare var ChickadeeXeusKernel: any;

// Functions one page script hangs on window for another to call.
declare var chickadeeAddExistingSuiteScript: any;
declare var chickadeeAddInlineTest: any;
declare var chickadeeApplyScanPayload: any;
declare var chickadeeCollapseInlineEditor: any;
declare var chickadeeEditorCommand: any;
declare var chickadeeExpandInlineEditor: any;
declare var chickadeeFlushGlobalInputs: any;
declare var chickadeeFlushPendingGlobalInputs: any;
declare var chickadeeFlushPendingSectionVars: any;
declare var chickadeeFlushSectionVars: any;
declare var chickadeeGetSuiteItems: any;
declare var chickadeePatternFamilyEditor: any;
declare var chickadeeReadScanPayload: any;
declare var chickadeeRefreshEditSurface: any;
declare var chickadeeRemountNotebook: any;
declare var chickadeeSaveChecksViaSuite: any;
declare var chickadeeSaveFamiliesViaSuite: any;
declare var chickadeeSaveNotebook: any;
declare var chickadeeSaveScriptViaSuite: any;
declare var chickadeeSaveToAssignment: any;
declare var chickadeeSubmitInPlace: any;
declare var initAchievementsEditor: any;
declare var initGeneratedStarterTests: any;
declare var initGlobalInputsEditor: any;
declare var initPatternFamilyEditor: any;
declare var initSectionInputsEditor: any;
declare var initSuiteTable: any;
declare var initSupportFiles: any;
declare var initTestEditorModal: any;

// Page state flags kept on window between scripts.
declare var __chickadeeTargetSection: any;
declare var __chickadeeTestEditorModal: any;
declare var __ckSubmitStartMs: any;
// Test seam: a node test or a page sets the grading worker factory.
declare var __CHICKADEE_GRADING_WORKER_FACTORY__: any;

// Third-party globals that the page or a worker loads.
declare var JSZip: any;
declare var loadPyodide: any;
// The xeus-r kernel's emscripten glue (bin/xr.js), loaded by importScripts.
declare var createXeusModule: any;

// The classic scripts also export for the node test suite through a guarded
// `typeof module` block. The suite has no @types/node, so declare the one name.
declare var module: any;
