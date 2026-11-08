### Security

- **Staff reach another user's notebook folder only for a course they staff (#2895).** A TA in any live course could read every user's JupyterLite folder deployment-wide, including other courses' solution notebooks and students' work. `mayReadUserFile` now admits the owner, an admin, or course staff of the live course that owns the setup in the path. A listing above a setup folder is the owner's or an admin's only. The static files and the contents API share the policy.
