### Fixed

- **BrightSpace grade clears now transmit the DELETE they sign (#1105).** The
  Valence transport dispatched only PUT/GET, so `clearGrade` signed a DELETE
  but sent a GET — D2L verifies the verb inside the signature, so every real
  grade removal 403'd terminally and silently. The transport now switches on
  the method (PUT/POST/DELETE/GET), "Sync now" re-queues errored clear rows
  (previously unrecoverable — no reaper touches `brightspace_grade_clears`),
  and a transport-level test stubs `app.client` to pin wire-verb ↔ signature
  agreement for PUT/GET/DELETE.
