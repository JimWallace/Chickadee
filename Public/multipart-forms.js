// Multipart form interceptor.
//
// All multipart/form-data uploads bypass the hidden _csrf body field because
// the body stream is not collected before CSRF middleware runs.  Intercept
// every such form and re-submit via fetch with x-csrf-token in the header.
//
// When the server responds with a redirect, fetch follows it and `res.url`
// is the final destination — point the browser there.  When the server
// responds with 200 (or any non-redirect HTML) we replace the document
// inline so the user sees the result page; previously this code did
// `window.location.href = res.url`, which navigated GET to the POST URL
// and surfaced a 404 for handlers that render a result view directly
// (admin / instructor bulk-enroll, etc.).  v0.4.119+.
//
// Lived inline at the foot of base.leaf until #1516 took 'unsafe-inline' out
// of the CSP script-src.  It carries no Leaf interpolation, so moving it to a
// file is a byte-for-byte lift.  A nonce would have been the wrong answer
// here in any case: this script hands the document to `document.write`, and a
// written document inherits the CSP of the response that wrote it, not a
// nonce minted for that second response.
(function () {
    // Surface an upload failure as an inline banner at the top of the form
    // (reusing the global .form-error styling) instead of a native dialog.
    function showUploadError(form, msg) {
        if (!form) return;
        var banner = form.querySelector('.js-upload-error-banner');
        if (!banner) {
            banner = document.createElement('div');
            banner.className = 'form-error js-upload-error-banner';
            banner.setAttribute('role', 'alert');
            form.insertBefore(banner, form.firstChild);
        }
        banner.textContent = msg;
        banner.scrollIntoView({ block: 'nearest' });
    }
    function clearUploadError(form) {
        var banner = form && form.querySelector('.js-upload-error-banner');
        if (banner) banner.remove();
    }

    document.addEventListener('submit', function (e) {
        var form = e.target;
        if (!form || form.enctype !== 'multipart/form-data') return;
        if (e.defaultPrevented) return;
        e.preventDefault();
        clearUploadError(form);
        form.dispatchEvent(new CustomEvent('chickadee:before-multipart-submit', { bubbles: false }));
        var csrfToken = ChickadeeUI.getCsrfToken();
        var btn = e.submitter || form.querySelector('[type="submit"]');
        if (btn) btn.disabled = true;
        // Respect formaction on the activating submit button (e.g. hidden draft-action buttons).
        var actionURL = (e.submitter && e.submitter.getAttribute('formaction')) || form.action;
        fetch(actionURL, {
            method: form.method.toUpperCase() || 'POST',
            headers: { 'x-csrf-token': csrfToken },
            body: new FormData(form)
        }).then(function (res) {
            if (res.redirected) {
                window.location.href = res.url;
                return;
            }
            // 200 OK with HTML body — render in place via document.open/write
            // so the result page replaces the form, with the same URL the
            // server saw (so a refresh resubmits — same as a native form
            // submit's behaviour).  document.write is deliberate here: the
            // result pages carry their own script tags, which a DOMParser /
            // replaceChild swap would NOT run.  Status text shown for non-OK
            // results.
            return res.text().then(function (html) {
                if (!res.ok && !html) {
                    showUploadError(form, 'Upload failed: ' + res.status + ' ' + res.statusText);
                    if (btn) btn.disabled = false;
                    return;
                }
                document.open();
                document.write(html);
                document.close();
            });
        }).catch(function (err) {
            showUploadError(form, 'Upload failed: ' + (err && err.message ? err.message : 'network error'));
            if (btn) btn.disabled = false;
        });
    });
}());
