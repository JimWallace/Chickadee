### Security

- **A TA can no longer change the BrightSpace binding or the sync identity (#2710).** Six actions on the instructor LEARN tab now require the course instructor role: connect, use my identity, bind org unit, auto-map, sync now and reconcile now. An archived course refuses them too. A TA keeps disconnect (their own account) and the connection test. A new test, `InstructorParameterlessRouteFloorTests`, declares a role floor for every `/instructor` write route without a path parameter and checks it as a TA.
