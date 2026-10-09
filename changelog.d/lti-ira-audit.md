### Security

- **LTI 1.3 security audit for the IRA.** `docs/compliance/lti-audit-2026-10.md` applies the Phase-1 audit controls to the LTI tool. The egress allowlist now lists the LTI platform hosts.
- **LTI service calls reach only the platform's registered hosts.** An AGS or NRPS URL from a launch, a line item ID or an NRPS next page on another host is refused before the access token is sent (audit L-1).
- **An LTI launch never signs in to an admin or MCP account through an existing link** (audit L-2).
- **An LTI context binds to a course by LEARN org unit only while one platform is enabled**, and the binding is audited (audit L-3).
