---
name: eg-tls
description: Configure TLS termination, passthrough, and cert-manager integration
arguments:
  - name: Mode
    description: "TLS mode: terminate, passthrough, mutual (default: terminate)"
    required: false
  - name: Issuer
    description: "cert-manager ClusterIssuer name (e.g., letsencrypt-prod)"
    required: false
---

Configure TLS for Envoy Gateway including certificate management, TLS termination, TLS passthrough, and mutual TLS (mTLS). This skill integrates with cert-manager for automatic certificate issuance and rotation, and covers BackendTLSPolicy for securing connections to backend services.

## Instructions

### Step 1: Set variables

Determine the TLS mode and issuer. If the user did not provide values, use these defaults:

- **Mode**: `terminate`
- **Issuer**: none (will generate a self-signed ClusterIssuer for development, or ACME for production)

### Step 2: Install cert-manager (if not already present)

Check if cert-manager is installed:

```bash
kubectl get deployment -n cert-manager cert-manager 2>/dev/null
```

If cert-manager is not installed, install it with Gateway API support enabled:

```bash
helm repo add jetstack https://charts.jetstack.io
helm install \
  cert-manager jetstack/cert-manager \
  --version v1.17.0 \
  --create-namespace --namespace cert-manager \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
```

Wait for cert-manager to be ready:

```bash
kubectl wait --for=condition=Available deployment -n cert-manager --all --timeout=2m
```

> **Important**: Gateway API CRDs must be installed before cert-manager starts (or cert-manager must be restarted after installing Gateway API CRDs) for the `gateway-shim` controller to detect Gateway resources.

### Step 3: Create a ClusterIssuer

Choose the appropriate issuer for your environment.

#### Self-signed issuer (development and testing only)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

> **WARNING (EGTM-001)**: Self-signed certificates are not trusted by browsers or clients. Never use self-signed certificates in production. They are suitable only for development and testing.

#### ACME HTTP-01 issuer with Let's Encrypt (production)

Create a staging issuer first to test certificate issuance without hitting rate limits:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    # Let's Encrypt staging environment (for testing)
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "${your-email@example.com}"    # TODO: Set your contact email
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - kind: Gateway
                name: eg                  # TODO: Name of your Gateway
                namespace: default        # TODO: Namespace of your Gateway
```

Once staging works, create the production issuer:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # Let's Encrypt production environment
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${your-email@example.com}"    # TODO: Set your contact email
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - kind: Gateway
                name: eg                  # TODO: Name of your Gateway
                namespace: default        # TODO: Namespace of your Gateway
```

Verify the ClusterIssuer is ready:

```bash
kubectl wait --for=condition=Ready clusterissuer/${Issuer}
kubectl describe clusterissuer/${Issuer}
```

> **HTTP-01 prerequisites**: For the ACME HTTP-01 challenge to work, the Gateway must be reachable on the public Internet and the domain must point to the Gateway's external IP. The Gateway must have an HTTP listener on port 80 for cert-manager to create temporary challenge HTTPRoutes.

### Step 4: Configure TLS based on mode

---

#### Mode: Terminate (default)

TLS termination at the Gateway. The Gateway decrypts incoming TLS traffic and forwards plaintext HTTP to backends. This is the most common mode.

##### Gateway with cert-manager annotation

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: default
  annotations:
    # cert-manager reads this annotation and automatically:
    # 1. Creates a Certificate resource
    # 2. Issues the certificate via the ClusterIssuer
    # 3. Stores the cert/key in the Secret referenced by certificateRefs
    # 4. Rotates the certificate before expiry
    cert-manager.io/cluster-issuer: "${Issuer}"   # TODO: Your ClusterIssuer name
spec:
  gatewayClassName: eg
  listeners:
    # HTTP listener (needed for ACME HTTP-01 challenges and HTTPS redirects)
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All

    # HTTPS listener with TLS termination
    - name: https
      protocol: HTTPS
      port: 443
      # hostname is REQUIRED for cert-manager to determine the certificate SANs.
      hostname: "www.example.com"         # TODO: Set your domain
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            # cert-manager auto-creates this Secret with the issued certificate.
            # The name can be anything; cert-manager will create it if it does not exist.
            name: eg-https                # TODO: Choose a Secret name
      allowedRoutes:
        namespaces:
          from: All
```

##### How cert-manager integration works

1. cert-manager's `gateway-shim` watches for Gateway resources with cert-manager annotations.
2. It reads the `hostname` from each TLS listener and the `certificateRefs` Secret name.
3. It creates a Certificate resource that matches the listener's hostname.
4. The configured ClusterIssuer issues the certificate (via ACME HTTP-01, self-signed, etc.).
5. cert-manager stores the signed certificate and private key in the referenced Secret.
6. Envoy Gateway detects the Secret update and reloads the Envoy proxy with the new certificate.
7. Before the certificate expires, cert-manager automatically renews it.

##### Manual TLS (without cert-manager)

If you prefer to manage certificates manually:

```bash
# Create a TLS Secret from your certificate files
kubectl create secret tls example-cert \
  --key=www.example.com.key \
  --cert=www.example.com.crt
```

Then reference the Secret in the Gateway listener's `certificateRefs` without the cert-manager annotation.

---

#### Mode: Passthrough

TLS passthrough forwards the encrypted TLS stream directly to the backend without decryption. The backend service must handle TLS termination itself. Use TLSRoute (not HTTPRoute) with this mode.

##### Gateway with TLS Passthrough listener

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
    - name: tls-passthrough
      protocol: TLS              # Use TLS protocol (not HTTPS)
      port: 443
      hostname: "app.example.com"  # TODO: SNI hostname for routing
      tls:
        mode: Passthrough        # Do NOT terminate TLS at the Gateway
      allowedRoutes:
        kinds:
          - kind: TLSRoute      # Only TLSRoute works with Passthrough
        namespaces:
          from: All
```

##### TLSRoute for passthrough traffic

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: tls-passthrough-route
  namespace: default
spec:
  parentRefs:
    - name: eg
      sectionName: tls-passthrough
  hostnames:
    - "app.example.com"          # Must match an SNI the listener accepts
  rules:
    - backendRefs:
        - name: secure-backend   # TODO: Backend that handles TLS termination
          port: 443
```

> **When to use passthrough**: Use TLS passthrough when the backend must terminate TLS itself, for example when the backend requires client certificate information, uses TLS features the Gateway does not support, or when you need true end-to-end encryption with no intermediary decryption.

---

#### Mode: Mutual TLS (mTLS)

Mutual TLS requires clients to present a valid certificate. This is configured using a ClientTrafficPolicy that references a CA certificate for client validation.

##### Step 1: Create the server certificate and CA Secret

```bash
# Create a root CA
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -subj '/O=example Inc./CN=example.com' \
  -keyout example.com.key -out example.com.crt

# Create a server certificate signed by the CA
openssl req -out www.example.com.csr -newkey rsa:2048 -nodes \
  -keyout www.example.com.key -subj "/CN=www.example.com/O=example organization"
openssl x509 -req -days 365 -CA example.com.crt -CAkey example.com.key \
  -set_serial 0 -in www.example.com.csr -out www.example.com.crt

# Create the server TLS Secret (includes CA for mTLS)
kubectl create secret tls example-cert \
  --key=www.example.com.key \
  --cert=www.example.com.crt \
  --certificate-authority=example.com.crt

# Create a separate Secret for the CA certificate (used for client validation)
kubectl create secret generic example-ca-cert \
  --from-file=ca.crt=example.com.crt
```

##### Step 2: Gateway with HTTPS listener

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: example-cert
      allowedRoutes:
        namespaces:
          from: All
```

##### Step 3: ClientTrafficPolicy for client certificate validation

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: enable-mtls
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  tls:
    clientValidation:
      caCertificateRefs:
        - kind: Secret
          group: ""
          name: example-ca-cert   # CA certificate for validating client certs
```

##### Step 4: Test with a client certificate

```bash
# Create a client certificate signed by the same CA
openssl req -out client.example.com.csr -newkey rsa:2048 -nodes \
  -keyout client.example.com.key -subj "/CN=client.example.com/O=example organization"
openssl x509 -req -days 365 -CA example.com.crt -CAkey example.com.key \
  -set_serial 0 -in client.example.com.csr -out client.example.com.crt

# Test with mutual TLS
curl --cert client.example.com.crt --key client.example.com.key \
  --cacert example.com.crt \
  -HHost:www.example.com \
  https://$GATEWAY_HOST/get
```

---

### Step 5: Backend TLS (Gateway to backend encryption)

BackendTLSPolicy secures the connection between the Gateway and backend Services. This provides end-to-end encryption even after TLS termination at the Gateway.

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata:
  name: backend-tls
  namespace: default
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: secure-backend      # TODO: The backend Service to connect to via TLS
  validation:
    caCertificateRefs:
      - group: ""
        kind: ConfigMap
        name: backend-ca-cert   # TODO: ConfigMap containing the backend's CA certificate
    hostname: backend.example.com  # TODO: Hostname the backend certificate must match
```

Create the CA ConfigMap:

```bash
kubectl create configmap backend-ca-cert \
  --from-file=ca.crt=backend-ca.crt
```

### Step 6: Verify TLS configuration

Check the Gateway status for TLS-related issues:

```bash
kubectl describe gateway/eg
```

Look for conditions like `InvalidCertificateRef` or `ResolvedRefs: False` which indicate certificate problems.

Verify cert-manager created the Certificate:

```bash
kubectl get certificate --all-namespaces
kubectl get certificaterequest --all-namespaces
```

Check the Secret was created with TLS data:

```bash
kubectl get secret eg-https -o jsonpath='{.type}'
# Expected: kubernetes.io/tls
```

For ACME issuers, monitor the Order and Challenge resources:

```bash
kubectl get order --all-namespaces -o wide
kubectl get challenge --all-namespaces
```

### Warnings

- **EGTM-001: Never use self-signed certificates in production.** Self-signed certificates are not trusted by clients and provide no identity verification. Use Let's Encrypt or another trusted CA for production deployments.
- **Certificate hostname matching**: The listener `hostname` must match the certificate's Subject Alternative Names (SANs). cert-manager automatically sets SANs from the listener hostname.
- **Single certificateRef**: While the Gateway API spec supports multiple `certificateRefs`, Envoy Gateway currently uses only the first one.
- **HTTP listener for ACME**: The ACME HTTP-01 solver requires an HTTP listener on port 80 on the same Gateway. cert-manager creates temporary HTTPRoutes for the challenge and removes them after validation.

## Checklist

- [ ] cert-manager is installed with Gateway API support enabled (`enableGatewayAPI=true`)
- [ ] ClusterIssuer is created and shows `Ready: True`
- [ ] Gateway has the `cert-manager.io/cluster-issuer` annotation (for cert-manager mode)
- [ ] HTTPS listener has `hostname` set (required for cert-manager)
- [ ] HTTPS listener references a Secret in `certificateRefs`
- [ ] Certificate resource was created by cert-manager and shows `Ready: True`
- [ ] TLS Secret exists and contains valid certificate data
- [ ] Gateway shows `Programmed: True` for all listeners
- [ ] For passthrough: TLSRoute is created with correct SNI hostname and backend
- [ ] For mutual TLS: ClientTrafficPolicy references a valid CA Secret
- [ ] For backend TLS: BackendTLSPolicy targets the correct Service with valid CA
- [ ] Self-signed certificates are NOT used in production (EGTM-001)
