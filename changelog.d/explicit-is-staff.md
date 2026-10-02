### Fixed

- **Every avatar names whether its wearer is staff.** `AvatarPresentation` had an overload that defaulted `isStaff` to false, and five of twelve sites never said otherwise: the admin runner job list drew an instructor's own submission under a student ring, and the account page's handle panel drew a staff-elsewhere student's stored ring beside a main bird wearing the staff ring. The overload is gone, so every site states the answer; the runner page asks the roster, the handle panel takes the page's answer, and a students-only list says `false` with the reason (#1758).
