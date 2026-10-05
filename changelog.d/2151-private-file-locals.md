### Changed

- **Forty-one file-local functions and constants in `Services/`, `Helpers/` and `Utilities/` are `private` (#2151).** A scan of every top-level symbol in the three directories found these referenced only inside their own file, so the compiler now keeps them there. No behaviour change.
