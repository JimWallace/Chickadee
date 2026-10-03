// Tests/APITests/GitHub/GitHubPayloadFixtures.swift
//
// GitHub's documented payloads for the three inbound shapes Chickadee decodes
// (#1775): a user (`GET /user`, `GET /user/{id}`), a commit
// (`GET /repos/{owner}/{repo}/commits/{ref}`) and a push delivery. Each one
// keeps the fields that carry personal data — names, email addresses, the
// pusher — because the tests that read them assert those fields are dropped.

enum GitHubPayloadFixtures {
    static let sha = "6dcb09b5b57875f334f61aebed695e2e4193db5e"

    /// `GET /user`, as GitHub documents it for an authenticated user.
    static let user = """
        {"login":"octocat","id":9001,"node_id":"MDQ6VXNlcjE=",
         "avatar_url":"https://github.com/images/error/octocat_happy.gif","gravatar_id":"",
         "url":"https://api.github.com/users/octocat","html_url":"https://github.com/octocat",
         "type":"User","site_admin":false,"name":"monalisa octocat","company":"GitHub",
         "blog":"https://github.com/blog","location":"San Francisco","email":"octocat@github.com",
         "hireable":false,"bio":"There once was...","twitter_username":"monatheoctocat",
         "public_repos":2,"public_gists":1,"followers":20,"following":0,
         "created_at":"2008-01-14T04:33:35Z","updated_at":"2008-01-14T04:33:35Z",
         "private_gists":81,"total_private_repos":100,"owned_private_repos":100,"disk_usage":10000,
         "collaborators":8,"two_factor_authentication":true,
         "plan":{"name":"Medium","space":400,"private_repos":20,"collaborators":0}}
        """

    /// `GET /repos/{owner}/{repo}/commits/{ref}`, as GitHub documents it.
    static let commit = """
        {"url":"https://api.github.com/repos/octocat/Hello-World/commits/\(sha)",
         "sha":"\(sha)","node_id":"MDY6Q29tbWl0NmRjYjA5YjViNTc4NzVmMzM0ZjYxYWViZWQ2OTVlMmU0MTkzZGI1ZQ==",
         "html_url":"https://github.com/octocat/Hello-World/commit/\(sha)",
         "commit":{"url":"https://api.github.com/repos/octocat/Hello-World/git/commits/\(sha)",
          "author":{"name":"Monalisa Octocat","email":"support@github.com","date":"2011-04-14T16:00:49Z"},
          "committer":{"name":"Monalisa Octocat","email":"support@github.com","date":"2011-04-14T16:00:49Z"},
          "message":"Fix all the bugs",
          "tree":{"url":"https://api.github.com/repos/octocat/Hello-World/tree/\(sha)","sha":"\(sha)"},
          "comment_count":0,
          "verification":{"verified":false,"reason":"unsigned","signature":null,"payload":null}},
         "author":{"login":"octocat","id":1,"type":"User","site_admin":false},
         "committer":{"login":"octocat","id":1,"type":"User","site_admin":false},
         "parents":[{"url":"https://api.github.com/repos/octocat/Hello-World/commits/\(sha)","sha":"\(sha)"}],
         "stats":{"additions":104,"deletions":4,"total":108},
         "files":[{"filename":"file1.txt","additions":10,"deletions":2,"changes":12,"status":"modified",
          "raw_url":"https://github.com/octocat/Hello-World/raw/\(sha)/file1.txt",
          "blob_url":"https://github.com/octocat/Hello-World/blob/\(sha)/file1.txt",
          "patch":"@@ -29,7 +29,7 @@\\n....."}]}
        """

    /// A `push` delivery, as GitHub documents it.
    static func push(repositoryID: Int64, after: String = sha) -> String {
        """
        {"ref":"refs/heads/main","before":"0000000000000000000000000000000000000000","after":"\(after)",
         "repository":{"id":\(repositoryID),"node_id":"R_kgDOA","name":"lab-1-octo-student",
          "full_name":"cs101-org/lab-1-octo-student","private":true,
          "owner":{"name":"cs101-org","email":null,"login":"cs101-org","id":7000,"type":"Organization"},
          "html_url":"https://github.com/cs101-org/lab-1-octo-student","default_branch":"main",
          "pushed_at":1696300000,"visibility":"private"},
         "pusher":{"name":"octo-student","email":"octo@example.com"},
         "organization":{"login":"cs101-org","id":7000},
         "installation":{"id":55,"node_id":"MDIzOkludGVncmF0aW9uSW5zdGFsbGF0aW9uNTU="},
         "sender":{"login":"octo-student","id":9001,"type":"User","site_admin":false},
         "created":false,"deleted":false,"forced":false,"base_ref":null,
         "compare":"https://github.com/cs101-org/lab-1-octo-student/compare/000000000000...6dcb09b5b578",
         "commits":[{"id":"\(after)","tree_id":"\(after)","distinct":true,"message":"Private message",
          "timestamp":"2026-10-02T12:00:00-04:00",
          "url":"https://github.com/cs101-org/lab-1-octo-student/commit/\(after)",
          "author":{"name":"Octo Student","email":"octo@example.com","username":"octo-student"},
          "committer":{"name":"Octo Student","email":"octo@example.com","username":"octo-student"},
          "added":["lab1.py"],"removed":[],"modified":[]}],
         "head_commit":{"id":"\(after)","tree_id":"\(after)","distinct":true,"message":"Private message",
          "timestamp":"2026-10-02T12:00:00-04:00",
          "url":"https://github.com/cs101-org/lab-1-octo-student/commit/\(after)",
          "author":{"name":"Octo Student","email":"octo@example.com","username":"octo-student"},
          "committer":{"name":"Octo Student","email":"octo@example.com","username":"octo-student"},
          "added":["lab1.py"],"removed":[],"modified":[]}}
        """
    }
}
