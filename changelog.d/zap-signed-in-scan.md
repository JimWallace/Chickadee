### Security

- **The weekly ZAP scan crawls the signed-in pages.** Without a session it reached five public URLs and every other page redirected to `/login` (#2193). The job now registers a throwaway account on its CI server, makes it the admin, an instructor in one course and a student in another, and passes its session cookie to ZAP. The spider submits no forms, so the signed-in crawl cannot sign out or delete what it scans.
