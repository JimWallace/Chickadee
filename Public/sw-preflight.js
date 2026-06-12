// Minimal service worker used only by the preflight check on the student
// submit page.  We register it, observe whether registration succeeded, and
// then immediately unregister.  This catches browsers / managed-device
// policies / privacy modes where the SW API is present but registration is
// silently blocked — a common reason JupyterLite fails to start.
self.addEventListener('install', function (event) {
    self.skipWaiting();
});
self.addEventListener('activate', function (event) {
    event.waitUntil(self.clients.claim());
});
