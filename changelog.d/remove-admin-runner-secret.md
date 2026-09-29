### Removed

- **Runner shared secret controls on the admin page.** The secret can no longer be shown or changed from `/admin`, and `POST /admin/runner-secret` is gone. Set `RUNNER_SHARED_SECRET` in the environment. If it is not set, the server generates a secret and keeps it in `.worker-secret`.
