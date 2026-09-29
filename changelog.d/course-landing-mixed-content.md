### Changed

- **Course landing sections show materials and labs in one list.** Each row now has a kind tile, a title with a details line, a status, a grade and icon actions. Materials use the same square icon buttons as labs. Section tables no longer re-sort, so readings stay beside the labs they were placed with. The Filter box appears only on sections with 8 or more rows. The History column is now a "N submissions" link in the details line.
- **Icon action buttons are a fixed square.** `.action-btn-icon` no longer sizes from padding, so four buttons fit one Actions cell on every page.

### Added

- **PDF attachments open in a new tab.** A new route, `/content-files/<item>/<attachment>/view`, serves a PDF inline. It accepts only a stored `.pdf` whose first bytes are `%PDF-`. Other files still download.
