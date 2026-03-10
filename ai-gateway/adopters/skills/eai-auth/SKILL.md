---
name: eai-auth
description: Configure BackendSecurityPolicy for AI provider authentication — API key, AWS, Azure, GCP credentials
arguments:
  - name: PolicyType
    description: "Type: APIKey, AnthropicAPIKey, AzureAPIKey, AzureCredentials, AWSCredentials, GCPCredentials"
    required: true
  - name: AIServiceBackendName
    description: "Name of the AIServiceBackend to attach the policy to"
    required: true
---

Configure authentication for AI backends using BackendSecurityPolicy. This policy attaches to AIServiceBackend or InferencePool and injects credentials when the gateway forwards requests to the provider. **Only one BackendSecurityPolicy can target a given AIServiceBackend or InferencePool**; multiple policies cause reconciliation failure.

## Instructions

### Step 1: Attach to AIServiceBackend

BackendSecurityPolicy uses `targetRefs` to attach to AIServiceBackend:

```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: BackendSecurityPolicy
metadata:
  name: ${AIServiceBackendName}-apikey  # TODO: Descriptive name
  namespace: default  # TODO: Match AIServiceBackend namespace
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: ${AIServiceBackendName}
  type: ${PolicyType}  # TODO: APIKey, AnthropicAPIKey, AzureAPIKey, etc.
  # ... provider-specific config below
```

### Step 2: API Key (OpenAI, generic)

For OpenAI and other providers that use `Authorization: Bearer <key>`:

```yaml
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: my-openai-backend
  type: APIKey
  apiKey:
    secretRef:
      name: openai-api-key-secret
      namespace: default
```

Create the secret (key must be `apiKey`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: openai-api-key-secret
  namespace: default
type: Opaque
stringData:
  apiKey: "sk-..."  # TODO: Replace with your API key
```

### Step 3: Anthropic API Key

Uses `x-api-key` header:

```yaml
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: my-anthropic-backend
  type: AnthropicAPIKey
  anthropicAPIKey:
    secretRef:
      name: anthropic-api-key-secret
      namespace: default
```

Secret key: `apiKey`

### Step 4: Azure OpenAI API Key

Uses `api-key` header:

```yaml
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: my-azure-openai-backend
  type: AzureAPIKey
  azureAPIKey:
    secretRef:
      name: azure-openai-api-key-secret
      namespace: default
```

Secret key: `apiKey`

### Step 5: AWS Credentials

For AWS Bedrock. Supports default credential chain (IRSA, Pod Identity, env vars), credentials file, or OIDC:

**Default credential chain** (recommended for EKS):

```yaml
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: my-bedrock-backend
  type: AWSCredentials
  awsCredentials:
    region: us-east-1
```

**Credentials file** (secret key: `credentials`):

```yaml
  awsCredentials:
    region: us-east-1
    credentialsFile:
      secretRef:
        name: aws-credentials-secret
        namespace: default
      profile: default
```

**OIDC (e.g., for non-EKS)**:

```yaml
  awsCredentials:
    region: us-east-1
    oidcExchangeToken:
      oidc:
        issuer: https://oidc.example.com
        # ... OIDC config
      awsRoleArn: arn:aws:iam::123456789012:role/MyBedrockRole
```

### Step 6: Azure Credentials (OAuth)

For Azure OpenAI with client secret or OIDC:

```yaml
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: my-azure-openai-backend
  type: AzureCredentials
  azureCredentials:
    clientID: "your-client-id"
    tenantID: "your-tenant-id"
    clientSecretRef:
      name: azure-client-secret
      namespace: default
```

Secret key: `client-secret`

### Step 7: GCP Credentials

For GCP Vertex AI. Requires project name and region. Supports credentials file or workload identity federation:

**Credentials file** (secret key: `service_account.json`):

```yaml
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: my-vertex-backend
  type: GCPCredentials
  gcpCredentials:
    projectName: my-gcp-project
    region: us-central1
    credentialsFile:
      secretRef:
        name: gcp-sa-secret
        namespace: default
```

**Workload Identity Federation** (for OIDC-based auth):

```yaml
  gcpCredentials:
    projectName: my-gcp-project
    region: us-central1
    workloadIdentityFederationConfig:
      projectID: my-gcp-project
      workloadIdentityPoolName: my-pool
      workloadIdentityProviderName: my-provider
      oidcExchangeToken:
        oidc:
          issuer: https://oidc.example.com
          # ...
      serviceAccountImpersonation:
        serviceAccountName: my-sa@my-project.iam.gserviceaccount.com
```

### Step 8: Multiple backends (one policy, many targets)

One BackendSecurityPolicy can target multiple AIServiceBackends (or InferencePools). Each target can have at most one policy:

```yaml
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: openai-backend-1
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: openai-backend-2
  type: APIKey
  apiKey:
    secretRef:
      name: shared-openai-key
      namespace: default
```

### Step 9: InferencePool target

For InferencePool backends (Gateway API Inference Extension):

```yaml
spec:
  targetRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: my-inference-pool
  type: APIKey
  apiKey:
    secretRef:
      name: inference-pool-secret
      namespace: default
```

## Checklist

- [ ] At most one BackendSecurityPolicy per AIServiceBackend or InferencePool
- [ ] BackendSecurityPolicy targetRefs point to correct AIServiceBackend(s) or InferencePool(s)
- [ ] Only one auth type per policy (no mixing APIKey with AWSCredentials)
- [ ] Secret created with correct key (apiKey, client-secret, credentials, service_account.json)
- [ ] For AWS: region specified; IRSA/Pod Identity preferred for Kubernetes
- [ ] For Azure: clientID and tenantID required
- [ ] For GCP: projectName and region required
