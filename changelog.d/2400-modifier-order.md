### Fixed

- **The confirm dialog is narrow again.** `.modal-card--confirm` came before `.modal-card` in the stylesheet, so the editor width won. A new check in `scripts/check-styles.sh` fails when a modifier rule comes before its base rule and sets the same property. (#2400)
