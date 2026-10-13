// APIServer/Views/CSRFField.swift
//
// The hidden CSRF form input. The CSRF middleware reads `_csrf` from the
// form body.

import Elementary

/// The hidden CSRF form field.
struct CSRFField: HTML {
    let token: String

    var body: some HTML {
        input(.type(.hidden), .name("_csrf"), .value(token))
    }
}
