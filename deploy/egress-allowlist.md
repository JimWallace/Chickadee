# Outbound network egress allowlist

Deployment-layer control for the Chickadee API server's **outbound** traffic.
The application has no built-in egress firewall; this restriction belongs in the
hosting environment (container/host firewall, a Squid forward proxy, or a
Kubernetes `NetworkPolicy`). It is part of the UW Information Risk Assessment
posture — see `docs/compliance/ira-audit-report.md` §5.

## What the server actually connects to

Chickadee's outbound destinations are a small, fixed set. **None of them is a
model / LLM API** — Chickadee *is* the MCP server an agent connects to; it never
calls a model itself (verified in `docs/compliance/data-flow-inventory.md`).

| Destination | Purpose | Driven by | Required? |
|-------------|---------|-----------|-----------|
| OIDC IdP host (e.g. UW DUO `sso-*.sso.duosecurity.com`) | SSO discovery, JWKS, token, revocation | `OIDC_AUTH_SERVER` | when `AUTH_MODE` is `sso`/`dual` |
| BrightSpace / D2L host (e.g. `d2l.uwaterloo.ca`) | Grade sync (Valence HMAC) | `BRIGHTSPACE_URL` | only if grade sync enabled |
| `uwaterloo.ca` | Academic-dates iCalendar feed (cached 24 h) | hard-coded | optional UI feature |
| Alert webhook host | Health alerts | operator-configured webhook | optional |
| Chickadee API server itself | Worker poll / report / artifact download | `WORKER_PUBLIC_BASE_URL` / internal | internal only |

If `OUTBOUND_HTTP_PROXY` is set, all of the above egress is funnelled through
that proxy; the allowlist can then be enforced at the proxy instead of per host.

**No model API endpoint appears in this list, and none should.** If a future
change adds an outbound call, update this file and
`docs/compliance/data-flow-inventory.md` in the same change.

## Option A — Squid forward proxy allowlist

Point the server at the proxy with `OUTBOUND_HTTP_PROXY=http://proxy-host:3128`
and allow only the destinations above. Replace the example hosts with your
deployment's actual IdP / D2L hosts.

```squid
# /etc/squid/conf.d/chickadee-egress.conf
acl chickadee_allowed dstdomain sso-4ccc589b.sso.duosecurity.com
acl chickadee_allowed dstdomain d2l.uwaterloo.ca
acl chickadee_allowed dstdomain .uwaterloo.ca
# Add your alert webhook host here if you use one.

http_access allow chickadee_allowed
http_access deny all
```

## Option B — host firewall (nftables)

When the server has a dedicated egress identity (its own user/uid or a
container), restrict outbound to the resolved destination set. Prefer the proxy
approach when hosts are DNS-based; firewalls match IPs, which can rotate.

```nft
table inet chickadee_egress {
    chain output {
        type filter hook output priority 0; policy drop;
        ct state established,related accept
        oifname "lo" accept
        # DNS so hostnames can resolve
        udp dport 53 accept
        tcp dport 53 accept
        # Allow only the resolved egress targets (fill in IPs / use ipset):
        ip daddr @chickadee_allowed_ips tcp dport 443 accept
        # Internal worker traffic stays on the cluster/private network.
    }
}
```

## Option C — Kubernetes NetworkPolicy

Default-deny egress, then allow DNS and the specific external hosts (via an
egress gateway or CIDR set) plus the in-cluster worker/DB services. Keep the
allowed external set to the table above.

## Verification

- Egress to a host *not* in the table above should fail.
- The MCP endpoint (`/mcp`) is **inbound** only; it is not affected by this
  allowlist. Restrict who may reach it with the `MCP_ALLOWED_HOSTS` /
  `MCP_ALLOWED_ORIGINS` guards and SSO/OAuth, not here.
