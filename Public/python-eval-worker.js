// Public/python-eval-worker.js
//
// The Python entry of the auto-compute worker. Everything else is eval-worker.js,
// which serves every in-page kernel language. `LanguageDescriptor` names this
// URL, so it stays (#2721).

self.ChickadeeEvalLanguage = 'python';
importScripts('/eval-worker.js' + (self.location.search || ''));
