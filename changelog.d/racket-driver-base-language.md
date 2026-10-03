### Changed

- **Racket personalization expressions evaluate faster.** The driver now starts from `racket/base` instead of the full `racket` language. This removes about 0.4 s from each evaluation, more than half of its run. Expressions still evaluate in the same base namespace, so no expression changes meaning (#2001).
