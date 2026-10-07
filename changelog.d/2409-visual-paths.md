### Changed

- **The visual and accessibility scan runs when web route code changes.** The route code builds each page's Leaf context, so a change there can change a page with no template edit. The workflow ran only for `Public/` and `Resources/Views/` changes. (#2409)
