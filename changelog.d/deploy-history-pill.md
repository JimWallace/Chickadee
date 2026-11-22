### Fixed

- **The Deployment history's Result pill sits after the title on a phone.**
  Its cell lacked the `item-status item-grade` classes that other
  `.section-items` lists put on their value cell, so at phone width the pill
  sat between the tile and the title. It now sits at the right of the title,
  as in the other lists. On a desktop the pill now right-aligns in its column,
  as every `.item-grade` value does.
