---
name: eg-auth
description: Configure authentication and authorization with SecurityPolicy — JWT, OIDC, API Key, ExtAuth, Basic Auth
arguments:
  - name: Method
    description: "Auth method: jwt, oidc, apikey, extauth, basic (default: jwt)"
    required: false
  - name: Target
    description: "Target resource: gateway or route name (default: applies to Gateway)"
    required: false
---

Configure authentication and authorization for Envoy Gateway using the SecurityPolicy CRD.
SecurityPolicy attaches to a Gateway (applies to all routes) or a specific HTTPRoute/GRPCRoute.
When a SecurityPolicy targets both a Gateway and a Route, the Route-level policy takes precedence.

## Instructions

### Step 1: Choose the target reference

Determine whether authentication applies at the Gateway level (all routes) or to a specific HTTPRoute.

For **Gateway-level** targeting (default):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <policy-name>  # TODO: Replace with a descriptive name
  namespace: <namespace>  # Must match the target resource namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: <gateway-name>  # TODO: Replace with your Gateway name
```

For **HTTPRoute-level** targeting:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <policy-name>
  namespace: <namespace>
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace with your HTTPRoute name
```

You can also use `targetSelectors` to match resources by label instead of name:

```yaml
spec:
  targetSelectors:
    - kind: HTTPRoute
      group: gateway.networking.k8s.io
      matchLabels:
        app: my-protected-app
```

### Step 2: Configure the authentication method

Select one of the following authentication methods based on the `Method` argument.

---

#### JWT Authentication (Method: jwt)

Validates JSON Web Tokens using remote or local JWKS. Best for service-to-service and API authentication.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: jwt-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  jwt:
    providers:
      - name: my-provider  # TODO: Name this provider (referenced in authorization rules)
        issuer: "https://issuer.example.com"  # TODO: Replace with your token issuer URL
        remoteJWKS:
          uri: "https://issuer.example.com/.well-known/jwks.json"  # TODO: Replace with your JWKS endpoint
```

**Using local JWKS** (stored in a ConfigMap instead of fetched remotely):

```yaml
  jwt:
    providers:
      - name: my-provider
        localJWKS:
          type: ValueRef
          valueRef:
            group: ""
            kind: ConfigMap
            name: jwt-local-jwks  # TODO: Create this ConfigMap with a "jwks" key
```

**Extract claims to headers** (forward JWT claims to the backend):

```yaml
  jwt:
    providers:
      - name: my-provider
        issuer: "https://issuer.example.com"
        remoteJWKS:
          uri: "https://issuer.example.com/.well-known/jwks.json"
        extractFrom:
          headers:
            - name: Authorization
              valuePrefix: "Bearer "
          # Also extract from cookies if needed:
          # cookies:
          #   - access-token
```

**Claims-based authorization** (require specific claim values):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: jwt-claim-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  jwt:
    providers:
      - name: my-provider
        issuer: "https://issuer.example.com"  # TODO: Replace
        remoteJWKS:
          uri: "https://issuer.example.com/.well-known/jwks.json"  # TODO: Replace
  authorization:
    defaultAction: Deny
    rules:
      - name: allow-admins
        action: Allow
        principal:
          jwt:
            provider: my-provider  # Must match the provider name above
            scopes: ["read", "write"]  # TODO: Replace with required scopes
            claims:
              - name: user.roles  # TODO: Replace with the claim path to check
                valueType: StringArray
                values: ["admin"]  # TODO: Replace with required claim values
```

---

#### OIDC Authentication (Method: oidc)

Redirects unauthenticated users to an OpenID Connect provider for interactive login. Best for web applications with browser-based users. Requires HTTPS on the Gateway listener.

First, create a Secret containing your OIDC client secret:

```yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: oidc-client-secret  # TODO: Choose a name
  namespace: <namespace>
stringData:
  client-secret: "<your-client-secret>"  # TODO: Replace with your OIDC client secret
```

Then create the SecurityPolicy:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: oidc-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  oidc:
    provider:
      issuer: "https://accounts.google.com"  # TODO: Replace with your OIDC provider issuer
    clientID: "<your-client-id>"  # TODO: Replace with your OIDC client ID
    clientSecret:
      name: oidc-client-secret  # Must match the Secret name above
    # redirectURL and logoutPath MUST match the target HTTPRoute's host and path prefix
    redirectURL: "https://www.example.com/myapp/oauth2/callback"  # TODO: Replace
    logoutPath: "/myapp/logout"  # TODO: Replace
    scopes:
      - openid
      - profile
      - email  # TODO: Adjust scopes as needed
    # Forward the access token to the backend via Authorization header:
    # forwardAccessToken: true
    # Share cookies across subdomains:
    # cookieDomain: "example.com"
```

Important: The `redirectURL` must be prefixed with the target HTTPRoute's host and path. The `logoutPath` must be prefixed with the HTTPRoute's path prefix. Register this redirect URL with your OIDC provider.

---

#### API Key Authentication (Method: apikey)

Validates requests against API keys stored in Kubernetes Secrets. Good for machine-to-machine API access.

First, create an Opaque Secret containing valid API keys (key = client ID, value = API key):

```yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: apikey-secret  # TODO: Choose a name
  namespace: <namespace>
stringData:
  client1: "supersecret-key-1"  # TODO: Replace with actual API keys
  client2: "supersecret-key-2"
  # NOTE: Do NOT include "Bearer " prefix in the values even if clients send
  # "Authorization: Bearer <key>". Envoy strips the prefix automatically.
```

Then create the SecurityPolicy:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: apikey-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  apiKeyAuth:
    credentialRefs:
      - group: ""
        kind: Secret
        name: apikey-secret  # Must match the Secret name above
    extractFrom:
      # Extract API key from a custom header:
      - headers:
          - x-api-key  # TODO: Change the header name if needed
      # Or extract from a query parameter:
      # - params:
      #     - api_key
      # Or extract from the Authorization header (Bearer scheme):
      # - headers:
      #     - Authorization
```

---

#### External Authorization (Method: extauth)

Delegates auth decisions to an external HTTP or gRPC service. Use ExtAuth when your authorization logic requires database lookups, custom business rules, or integration with systems not natively supported by Envoy Gateway.

**HTTP ExtAuth:**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ext-auth-http
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  extAuth:
    http:
      backendRefs:
        - name: http-ext-auth  # TODO: Replace with your auth service name
          port: 9002  # TODO: Replace with your auth service port
      headersToBackend:
        - x-current-user  # Headers from auth response to forward to the backend
    # Optional: send specific headers to the auth service
    # By default HTTP ExtAuth only receives: Host, Method, Path, Content-Length, Authorization
    headersToExtAuth:
      - x-custom-header  # TODO: Add headers your auth service needs
    # failOpen: false  # Set to true to allow traffic if the auth service is unavailable
    # timeout: 10s  # Timeout for auth service requests (default: 10s)
```

**gRPC ExtAuth:**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ext-auth-grpc
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  extAuth:
    grpc:
      backendRefs:
        - name: grpc-ext-auth  # TODO: Replace with your gRPC auth service name
          port: 9002  # TODO: Replace with your gRPC auth service port
    # gRPC services receive ALL request headers by default (unlike HTTP)
    # failOpen: false
    # timeout: 10s
```

When to use ExtAuth vs. built-in methods:
- Use JWT/OIDC/API Key when the built-in methods cover your requirements -- they are simpler, faster, and need no external service.
- Use ExtAuth when you need custom logic, database lookups, or integration with authorization systems like OPA, Casbin, or proprietary services.

---

#### Basic Auth (Method: basic)

**WARNING (EGTM-023)**: Basic authentication uses SHA1 hashing and does not enforce password complexity. It is recommended to use JWT or OIDC instead. If you must use Basic Auth, always pair it with TLS to prevent credentials from being transmitted in plain text.

First, generate an htpasswd file and create a Secret:

```bash
# Generate .htpasswd file (SHA algorithm)
htpasswd -cbs .htpasswd user1 password1
htpasswd -bs .htpasswd user2 password2

# Create the Kubernetes Secret
kubectl create secret generic basic-auth --from-file=.htpasswd -n <namespace>
```

Then create the SecurityPolicy:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: basic-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  basicAuth:
    users:
      name: basic-auth  # Must match the Secret name above
    # forwardUsernameHeader: x-username  # Optional: forward authenticated username to backend
```

---

### Step 3: Configure authorization rules (optional)

Authorization rules work independently or alongside any authentication method. They control which authenticated requests are allowed or denied.

**IP-based allow/deny lists:**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ip-allow-list
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  authorization:
    defaultAction: Deny
    rules:
      - name: allow-internal
        action: Allow
        principal:
          clientCIDRs:
            - 10.0.0.0/8  # TODO: Replace with your allowed CIDR ranges
            - 192.168.0.0/16
```

**JWT claim-based authorization** (combine with JWT authentication):

```yaml
  authorization:
    defaultAction: Deny
    rules:
      - name: allow-by-claim
        action: Allow
        principal:
          jwt:
            provider: my-provider  # Must match a JWT provider name
            claims:
              - name: groups
                valueType: StringArray
                values: ["engineering", "platform"]
```

### Step 4: Configure CORS (optional)

CORS can be configured in the same SecurityPolicy alongside authentication.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: cors-and-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  cors:
    allowOrigins:
      - "https://app.example.com"  # TODO: Replace with your allowed origins
      - "https://*.example.com"  # Wildcard subdomain support
    allowMethods:
      - GET
      - POST
      - PUT
      - DELETE
    allowHeaders:
      - Authorization
      - Content-Type
    exposeHeaders:
      - X-Request-Id
    maxAge: 86400s  # Cache preflight for 24 hours
    # allowCredentials: true  # Enable if cookies/auth headers needed cross-origin
  jwt:
    providers:
      - name: my-provider
        issuer: "https://issuer.example.com"
        remoteJWKS:
          uri: "https://issuer.example.com/.well-known/jwks.json"
```

### Step 5: Apply and verify

```bash
kubectl apply -f security-policy.yaml

# Verify the SecurityPolicy status
kubectl get securitypolicy/<policy-name> -o yaml

# Check that conditions show Accepted: True
kubectl get securitypolicy/<policy-name> -o jsonpath='{.status.conditions}'
```

## Checklist

- [ ] SecurityPolicy targets the correct resource (Gateway or HTTPRoute) in the same namespace
- [ ] For JWT: issuer URL and JWKS URI are correct and reachable from the cluster
- [ ] For OIDC: redirectURL and logoutPath match the target HTTPRoute host and path prefix
- [ ] For OIDC: client secret is stored in an Opaque Secret with key "client-secret"
- [ ] For OIDC: HTTPS listener is configured on the Gateway (OIDC requires TLS)
- [ ] For API Key: Secret values do NOT include "Bearer " prefix
- [ ] For ExtAuth: auth service is deployed and reachable within the cluster
- [ ] For Basic Auth: TLS is enabled (EGTM-023 -- never use Basic Auth over plain HTTP)
- [ ] For Basic Auth: consider migrating to JWT/OIDC for stronger authentication
- [ ] CORS allowOrigins are restricted to known domains (avoid wildcard "*" in production)
- [ ] Authorization defaultAction is set to Deny when using allow-list rules
- [ ] Route-level SecurityPolicy is aware that it overrides any Gateway-level SecurityPolicy
- [ ] SecurityPolicy status shows Accepted: True with no error conditions
