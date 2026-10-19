// Public/octave-eval-worker.js
//
// The Octave entry of the auto-compute worker. Everything else is eval-worker.js,
// which serves every in-page kernel language. `LanguageDescriptor` names this
// URL, so it stays (#2721).

self.ChickadeeEvalLanguage = 'octave';
importScripts('/eval-worker.js' + (self.location.search || ''));
