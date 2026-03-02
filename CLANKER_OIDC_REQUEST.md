# Add OIDC env-var support

Please update OIDC config loading so it supports these environment variables for local dev:

```dotenv
# for local dev http://localhost:8000
OIDC_AUTH_SERVER=https://sso-4ccc589b.sso.duosecurity.com/oidc/DIUHIIU5GLVCYFDLE7P7/
OIDC_CLIENT_ID=DIUHIIU5GLVCYFDLE7P7
OIDC_CLIENT_SECRET=XXXXXXXXXXX
OIDC_CALLBACK=/oidc/duo/callback/
```

## Required changes

1. Read `OIDC_AUTH_SERVER` in `Sources/APIServer/Auth/OIDCConfiguration.swift`.
2. Build discovery URL from `OIDC_AUTH_SERVER` instead of hardcoding DUO host.
3. Read `OIDC_CALLBACK` and use it when constructing `redirectURI`.
4. Keep backward compatibility:
   - If `OIDC_AUTH_SERVER` is missing, fall back to current DUO pattern.
   - If `OIDC_CALLBACK` is missing, fall back to `/auth/sso/callback`.
5. Keep existing behavior for `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`.

## Validation

1. Startup succeeds with only existing vars (`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`).
2. Startup succeeds with all four vars set.
3. SSO start route uses configured callback in `redirect_uri`.
4. Existing SSO tests still pass, and add/adjust tests for env fallbacks.
