### Fixed

- **The LTI assignment picker no longer depends on a cookie.** Brightspace's picker frame still lost the launch-state cookie in Safari 26.6, which supports partitioned cookies, so the picker stayed empty. A deep-linking launch now signs nobody in and does not need the cookie; the platform's signature, the single-use state, the nonce, the staff role and the picker's own single-use ticket still guard it. A launch that signs someone in still requires the cookie, and a cookie that names another login's state is refused on every launch.
