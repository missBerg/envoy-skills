---
name: eg-security-guide
description: Envoy Gateway security best practices — threat model findings, RBAC, TLS, authentication hardening
---

# Envoy Gateway Security

## 4-Tier RBAC Model (Gateway API)

| Role | Scope | Manages |
|------|-------|---------|
| **Infrastructure Provider** | Cluster-wide | GatewayClass, Envoy Gateway controller deployment |
| **Cluster Operator** | Cluster/namespace | Gateways, TLS certificates, cluster-wide policies |
| **Application Admin** | Namespace | Routes, SecurityPolicy, BackendTrafficPolicy for their apps |
| **Application Developer** | Namespace | Services, Deployments, backend configuration |

- Map these roles to Kubernetes RBAC ClusterRoles/Roles
- Principle of least privilege: developers should not create Gateways or GatewayClasses

## Threat Model Findings and Mitigations

- **EGTM-001**: Never use self-signed certificates in production. Use certificates from a trusted CA. Self-signed certs disable TLS verification and enable MITM attacks.
- **EGTM-002**: Use cert-manager with a real CA (Let's Encrypt, Vault, AWS ACM) for automated certificate lifecycle. Manual certificate management leads to expiration outages and key sprawl.
- **EGTM-004**: The default EG ClusterRole grants broad permissions. Use **namespaced deployment mode** to restrict the controller's scope to specific namespaces.
- **EGTM-018**: Enable **rate limiting** (ClientTrafficPolicy or BackendTrafficPolicy) to protect against DoS. Configure both local and global rate limits for defense in depth.
- **EGTM-023**: Prefer **JWT/OIDC** over Basic Auth. Basic Auth transmits credentials on every request and has no built-in expiration or revocation. If Basic Auth is unavoidable, always pair it with TLS.

## Authentication Hardening

- Always use **SecurityPolicy** for authentication configuration. Never configure auth filters manually via EnvoyPatchPolicy.
- Prefer this auth hierarchy: **OIDC > JWT > API Key > ExtAuth > Basic Auth**
- For JWT: always set `issuer` and `audiences` to prevent token confusion attacks
- For OIDC: use PKCE flow, set secure `redirectURL`, validate `logoutPath`
- API Keys: store in Kubernetes Secrets, rotate regularly, scope per route

## TLS

- Terminate TLS at the Gateway for all external traffic
- Enable **mTLS for backend connections** via BackendTLSPolicy where possible
- Minimum TLS version: TLSv1.2 (prefer TLSv1.3)
- Use strong cipher suites; disable CBC-mode ciphers
- Configure HSTS headers via response header modification

## Proxy Hardening

- **Path normalization**: must be enabled to prevent path confusion attacks (e.g., `/admin/../secret`)
- **Reject headers with underscores**: set `headers_with_underscores_action: REJECT_REQUEST` in EnvoyProxy bootstrap to prevent header injection via underscore-to-hyphen conversion
- **use_remote_address**: set to `true` on edge proxies so Envoy uses the downstream connection's IP for access logging, rate limiting, and authorization
- **Admin interface**: restrict to localhost (`127.0.0.1`) in production; never expose externally
- **Envoy image**: use the latest patched Envoy Proxy image; enable vulnerability scanning in CI

## Authorization

- Use SecurityPolicy `authorization` rules to enforce RBAC at the route level
- Default deny: explicitly allow required paths, deny everything else
- Combine JWT claims-based authorization with route-level rules for fine-grained access control
