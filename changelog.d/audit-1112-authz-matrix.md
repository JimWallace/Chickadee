### Added

- **Route-walking authorization matrix test (#1112).** The web-side sibling of
  `MCPAuthorizationCoverageTests`: walks the live route table, substitutes
  fixture IDs into every parameterized `/instructor` and `/courses` route, and
  asserts each denies (401/403/404) both a student of the owning course and
  staff of a different course. Route enumeration makes it self-updating — a
  new route with an unknown parameter fails with instructions to extend the
  fixture map, and a new resource route that forgets its per-course gate fails
  with the route named (the class of miss that produced #1103).
