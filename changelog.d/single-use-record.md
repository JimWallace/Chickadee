### Changed

- **The single-use burn is a shared helper.** The atomic `UPDATE … WHERE consumed = false RETURNING` primitive that OAuth codes, consent tokens, LTI login states and deep-link tickets all consume through moved from `MCPOAuthRoutes` to `SingleUseRecord.burn`. No behaviour change (#1650).
