### Fixed

- **`get_instructor_card_series` names the offering it describes.** A bare course code shared by several offerings resolves to the newest term, and the result gave no way to see which one answered. The payload now carries `courseCode`, `courseKey` and `courseTerm` beside the windows, as every content tool that names a course does (#1781).
