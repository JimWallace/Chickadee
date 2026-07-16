// Account page: personal-data export status poll (#557).
//
// Loaded only while the page shows an in-progress export. Polls the status
// endpoint and reloads the page once generation reaches a terminal state so
// the download button (or failure notice) appears without a manual refresh.
(function () {
    "use strict";
    if (!document.getElementById("export-pending")) { return; }
    var timer = setInterval(function () {
        fetch("/account/export/status", { headers: { "Accept": "application/json" } })
            .then(function (res) { return res.json(); })
            .then(function (body) {
                if (body.status !== "pending") {
                    clearInterval(timer);
                    window.location.replace("/account");
                }
            })
            .catch(function () {});
    }, 3000);
})();
