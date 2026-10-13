### Changed

- **CSRF protection is Chickadee's own `CSRFMiddleware`.** It replaces the `vapor-community/CSRF` package, which depended on Leaf for a form-field tag that Chickadee did not use. The token format and the session key are the same, so a page that was open during the deploy still submits. `leaf`, `leaf-kit` and `csrf` are gone from `Package.resolved`.
