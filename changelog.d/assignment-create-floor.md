### Security

- **A TA can no longer create an assignment.** Quick publish (`POST /instructor`), save (`POST /instructor/new/save`) and the draft that starts a new assignment (`POST /instructor/new/draft`) now require the course instructor role, as the role docs say. An archived course refuses them too. `InstructorParameterlessRouteFloorTests` found the gap (#2710); its known-gap list is now empty.
