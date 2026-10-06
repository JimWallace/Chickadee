### Fixed

- **get_assignment_version no longer returns binary files as text.** It read capped content by dropping one byte at a time and decoding the whole prefix again, which was quadratic and returned the ASCII start of a binary file as truncated text. It now shares one capped UTF-8 reader and one byte cap with `get_support_files`, and refuses content that is not UTF-8. (#2334)
