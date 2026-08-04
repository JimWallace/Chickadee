### Fixed

- **Writes in the workbench no longer navigate the editor pane away.** Every
  form on the assignment editor — Save, Create solution, the secret-reveal
  toggle, and suite-section create/rename/delete — redirects to the chromed
  standalone editor when it succeeds. Inside the workbench that redirect landed
  *in the left pane*, so adding a suite section replaced the editor with a
  second copy of itself under the workbench's own Save button; because the
  standalone page is not cross-origin isolated, the browser then refused it
  under `require-corp` and the pane went blank. Those writes are now fetched and
  the pane re-renders itself, keeping the author's scroll position. The
  standalone `/edit` page is unchanged and still follows its redirects.
- **The workbench's Save reports the real result.** It replied "saved" before
  submitting, because the pane was about to navigate and a later reply would
  never arrive — so a failed save looked like a successful one.
- **`Create solution` no longer redirects to a 404.** It writes a draft
  notebook, but the solution resolver only looked in the test-setup zip and at
  validation submissions, so its own redirect target reported that no solution
  existed. Every other place that asks whether an assignment has a solution
  already counted the draft, which is why the Files table showed an Edit button
  beside a dead link.
