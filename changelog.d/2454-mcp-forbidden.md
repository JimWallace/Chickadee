### Fixed

- **An MCP agent refused for permission now gets `notAuthorized`, not `invalidArguments`.** A 401 or 403 from a shared web path told the agent that its arguments were wrong, although no argument could make the call succeed. It now maps to the error the tools already throw for an enrolment refusal. Every other 4xx still maps to `invalidArguments`. (#2454)
