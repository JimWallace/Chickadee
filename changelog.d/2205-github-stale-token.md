### Fixed

- **A renewed GitHub token is used for the rest of the request.** After GitHub refused a cached installation token, every later call in the same request started from the refused token again, and the tarball download and the commit status post could not renew it at all. Calls now start from the cached token, the tarball maps a refusal to a renewal, and the status post and the fork check go through the same retry.
