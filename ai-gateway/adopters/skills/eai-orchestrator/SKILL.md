---
name: eai-orchestrator
description: Orchestrate a complete Envoy AI Gateway setup — interview user and compose eai-install, eai-route, eai-backend, eai-auth
arguments: []
---

Orchestrate a full Envoy AI Gateway deployment by asking intake questions and composing the appropriate atomic skills. Use this when the user wants to set up AI Gateway from scratch or add a new provider.

## Intake Questions

Before generating configuration, ask:

1. **Installation**
   - Do you already have Envoy Gateway installed? If not, we need `/eai-install`.
   - Do you need rate limiting or InferencePool? (addons)

2. **Provider**
   - Which AI provider(s)? (OpenAI, Anthropic, AWS Bedrock, Azure OpenAI, GCP Vertex AI, Cohere, self-hosted/Ollama, etc.)
   - For cloud providers: How will you authenticate? (API key, IRSA/Pod Identity, service account, etc.)

3. **Routing**
   - Route by model? (e.g., gpt-4o-mini → backend A, claude-3-5-sonnet → backend B)
   - Need failover or traffic splitting?

4. **Environment**
   - Namespace for Gateway and routes?
   - Gateway name (if reusing existing)?

## Composition Flow

1. **If fresh install**: Run `/eai-install` with user's version/namespace preferences.
2. **Gateway + ClientTrafficPolicy**: Ensure Gateway exists and has ClientTrafficPolicy with `bufferLimit: 50Mi`.
3. **For each provider**:
   - Run `/eai-backend` with BackendName, Schema, Hostname, Port.
   - Run `/eai-auth` with PolicyType and AIServiceBackendName; create Secret if API key.
   - Add BackendTLSPolicy for HTTPS backends.
4. **Route**: Run `/eai-route` with GatewayName, BackendNames, and optional ModelHeader for each rule.

## Example: OpenAI + Anthropic

**Intake**: User wants OpenAI (gpt-4o-mini) and Anthropic (claude-3-5-sonnet) behind one Gateway.

**Generated flow**:

1. Install (if needed): `/eai-install`
2. Gateway + ClientTrafficPolicy (from eai-route skill)
3. Backend + AIServiceBackend for OpenAI: `/eai-backend` BackendName=openai, Schema=OpenAI, Hostname=api.openai.com, Port=443
4. BackendSecurityPolicy + Secret for OpenAI: `/eai-auth` PolicyType=APIKey, AIServiceBackendName=openai
5. BackendTLSPolicy for api.openai.com
6. Backend + AIServiceBackend for Anthropic: `/eai-backend` BackendName=anthropic, Schema=Anthropic, Hostname=api.anthropic.com, Port=443
7. BackendSecurityPolicy + Secret for Anthropic: `/eai-auth` PolicyType=AnthropicAPIKey, AIServiceBackendName=anthropic
8. BackendTLSPolicy for api.anthropic.com
9. AIGatewayRoute with two rules:
   - Match x-ai-eg-model=gpt-4o-mini → openai
   - Match x-ai-eg-model=claude-3-5-sonnet → anthropic

## Checklist

- [ ] All intake questions answered
- [ ] Install steps included if needed
- [ ] ClientTrafficPolicy with bufferLimit on Gateway
- [ ] Each provider has Backend + AIServiceBackend + BackendSecurityPolicy + BackendTLSPolicy (for HTTPS)
- [ ] AIGatewayRoute rules match user's routing intent
- [ ] Secrets created for API keys (never hardcode keys in YAML)
