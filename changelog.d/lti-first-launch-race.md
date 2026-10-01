### Fixed

- **Two first LTI launches of one subject no longer race to a 500.** When both tried to create the account or the identity link at once, the loser's insert failed on a unique index. The resolver now runs once more after such a failure and finds what the winner wrote. The LTI doc also records why `target_link_uri` is required and never routed on (#1661).
