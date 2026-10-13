### Fixed

- **The People and Students polls answer 304 when nothing changed.** The rows carry CSRF tokens, and each token has a fresh random salt, so the ETag of the rows changed on every poll and the table repainted every five seconds. The ETag now leaves the token out. The rows a client keeps on a 304 have older tokens, which stay valid for the same session.
