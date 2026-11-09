### Fixed

- **The editor kernel lists the drive root correctly (#2924).** On the server drive, a student's `os.listdir('/drive')` returned an empty list, because the root answered with the contents of the student's own folder. It now lists `users`, which lists only the student's own folder.
