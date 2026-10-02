### Fixed

- A cached GitHub installation token that GitHub refuses is dropped and resolved once more, and an `installation` webhook that removes or suspends the App drops the token at once. Before, a removed or re-made installation read as "GitHub did not respond" for up to an hour (#1768).
