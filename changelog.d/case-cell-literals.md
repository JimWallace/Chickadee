### Fixed

- **Case cells read the assignment language's literals.** A pattern-family case cell accepted only Python's `True`, `False` and `None`. So an R author who typed `TRUE` as an argument stored the string "TRUE", and the generated test passed a string. The case cells, the family Variables table and the inputs editors now use one parser, `ChickadeeLanguage.parseValue` (#1958).
