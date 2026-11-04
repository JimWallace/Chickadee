// @ts-check
// Minimal service worker used only by the preflight check on the student
// submit page.  We register it, observe whether registration succeeded, and
// then immediately unregister.  This catches browsers / managed-device
// policies / privacy modes where the SW API is present but registration is
// silently blocked — a common reason JupyterLite fails to start.
// jsconfig.json has no WebWorker lib, so `self` types as Window here. It is a
// ServiceWorkerGlobalScope at run time.
self.addEventListener('install', function () {
    /** @type {any} */ (self).skipWaiting();
});
self.addEventListener('activate', function (/** @type {any} ExtendableEvent */ event) {
    event.waitUntil(/** @type {any} */ (self).clients.claim());
});
