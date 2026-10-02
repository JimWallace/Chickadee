### Security

- **A course repository invites the student's current GitHub login, not the stored one.** The login stored at link time named the repository and the collaborator. GitHub releases a renamed login for anyone to take, so a stale one could invite a stranger with write access. The server now reads the current login from the linked numeric ID before it makes a repository or sends an invitation, and stores it. When no account has the ID, nothing is made or sent, and the student is asked to link again (#1766).
