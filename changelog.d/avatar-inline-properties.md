### Changed

- **The per-student avatar properties are listed once.** `AvatarPresentation.inlineProperties` pairs each `--av-*` name with the field the partial reads and the token it carries; `tokens` derives from it, and the partial test asserts every entry is assigned in both announce branches and that the partial assigns nothing the list does not name. A sixth token could previously pass the palette test and reach the page unassigned in one branch. The three comments that counted the properties (four, seven) cite the list (#1761).
