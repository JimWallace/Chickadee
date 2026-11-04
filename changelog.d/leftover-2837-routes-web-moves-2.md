### Changed

- **Nine course, enrollment and staff files leave `Routes/Web`.** The form and path types move to `Utilities/`, the request-bound loaders and staff provisioning to `Helpers/`, and the CSV roster enrollment to `Services/UsernameEnrollment.swift`. These are pure moves with no change in behaviour (#2837).
