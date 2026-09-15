### Fixed

- **Closed five mutation survivors in the submission normalizer.** Each had
  carried in every weekly sweep since `Sources/Worker` joined the scope. They
  pin student-visible behaviour the suite could not previously see change: a
  protected file being refused without the warning that names it (#1357), a
  lone unsupported file being rejected as the generic "no sources found"
  instead of by name, a compatibility copy repointing the preferred student
  module away from the file the student actually wrote, and the file walk's
  sort order — which decides which source becomes that preferred module.
