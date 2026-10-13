### Removed

- **Leaf is gone from the server.** Every page is an Elementary view, so the server no longer configures Leaf or registers its seven custom tags, and `Package.swift` no longer depends on `vapor/leaf`. `Package.resolved` still lists `leaf` and `leaf-kit`, because `vapor-community/CSRF` depends on them for its own form-field tag; Chickadee imports neither.

### Changed

- **The error-page middleware is `ErrorPageMiddleware`.** It was `LeafErrorMiddleware`. Its behaviour is unchanged: browser routes get the branded `ErrorPage`, and `/api/` and `/worker/` routes get JSON.
- **The two SVG sprites moved to `Resources/Sprites/`.** The icon sprite is `icons.svg` and the avatar sprite is `avatar-sprite.svg`. Their bytes are unchanged. The server reads them from the new paths at startup, and the Docker image already ships all of `Resources/`.
- **The Leaf templates are deleted.** `Resources/Views/` is gone. The tests and guards that read `.leaf` files now read the Swift views or a rendered fixture page: the page-archetype exemplars, the row-menu and list-filter markup tests, the drift tests, the avatar tests and the node tests.
- **The UI guard scripts check Swift views only.** `check-leaf-semantics.sh` and its fixtures are deleted. Its two remaining rules, per-page inline custom properties and a sort header with no sortable table, are now rendered-markup rules in `ElementaryPageGuardTests`.

### Fixed

- **The submission page section headings no longer skip a level.** They are `h2` under the page `h1`. Before, they were `h3`.
