---
name: eg-production-guide
description: Envoy Gateway production deployment — deployment modes, performance tuning, observability, operational guidance
---

# Envoy Gateway Production Deployment

## Deployment Modes

### Single Tenant (Default)
- One GatewayClass per Envoy Gateway controller
- Simplest model; suitable for most single-team deployments
- All Gateways share the same controller and Envoy Proxy fleet

### Multi-Tenant
- Deploy separate Envoy Gateway controllers per tenant namespace
- Each controller must have a **unique controller name** in its GatewayClass
- Provides strong tenant isolation at the control plane level
- Install via separate Helm releases with distinct `--set config.envoyGateway.gateway.controllerName=...`

### Gateway Namespace Mode
- Envoy Proxy pods deploy in the **Gateway's namespace** instead of the controller namespace
- Provides stronger workload isolation: proxy runs alongside the application
- Enables **JWT authentication between proxy and controller** for hardened communication
- Enable with `envoyGateway.provider.kubernetes.deploy.type: Namespace`

### Merged Gateways
- Merge listeners from **multiple Gateway resources** into a single Envoy Proxy fleet
- All merged Gateways share a single IP address / load balancer
- Useful for consolidating ingress when teams own different Gateways but share infrastructure
- Enable with `mergeGateways: true` on the GatewayClass parametersRef (EnvoyProxy)

## Performance Tuning

- **Connection timeouts**: set explicitly in ClientTrafficPolicy and BackendTrafficPolicy. Never rely on Envoy defaults.
  - `timeout.http.requestTimeout` — total time for the client to send a complete request
  - `timeout.http.idleTimeout` — close connections idle longer than this
- **HTTP/2 max concurrent streams**: limit to **100** to prevent a single connection from monopolizing resources
- **Buffer limits**: set to **32 KiB** for both listener and cluster buffers to cap memory under load
  - Configure via EnvoyProxy `spec.bootstrap` or EnvoyPatchPolicy
- **Resource requests/limits**: always set CPU and memory on Envoy Proxy pods via EnvoyProxy `spec.provider.kubernetes.envoyDeployment.container.resources`
- **Horizontal scaling**: use HPA on the Envoy Proxy Deployment; scale on CPU utilization (target 60-70%)
- **Keep-alive**: enable TCP keep-alive on backend connections to avoid connection resets through cloud load balancers

## Observability

### Access Logging
- Configure via EnvoyProxy `spec.telemetry.accessLog`
- Sinks: **File** (stdout/path) or **OpenTelemetry** (gRPC collector)
- Use structured JSON format for machine parsing
- Include at minimum: method, path, response code, duration, upstream host

### Metrics
- Expose Prometheus metrics via EnvoyProxy `spec.telemetry.metrics`
- Scrape from Envoy Proxy pods on the admin port (default 19001)
- Key metrics: `envoy_http_downstream_rq_total`, `envoy_http_downstream_rq_xx`, `envoy_cluster_upstream_rq_time`
- Enable Envoy Gateway controller metrics for control plane health

### Tracing
- Configure distributed tracing via EnvoyProxy `spec.telemetry.tracing`
- Export to **OpenTelemetry** collector (gRPC or HTTP)
- Set appropriate sampling rate: 1-10% in production, 100% in staging
- Propagate trace context headers (`traceparent`, `tracestate`)

## Operations

### Installation
```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  -n envoy-gateway-system \
  --create-namespace
```
- **Always pin Helm chart versions** — never use `latest` or omit `--version`
- Use `helm upgrade --install` for idempotent deployments

### GitOps
- Manage all Gateway API resources via **GitOps** (ArgoCD, Flux)
- Store Gateway, Route, and Policy manifests in version control
- Implement **mandatory PR reviews** for all gateway configuration changes
- Use SCM branch protection rules on the main branch

### Upgrade Strategy
- Upgrade Envoy Gateway controller first, then verify CRD compatibility
- Test upgrades in a staging environment that mirrors production topology
- Review release notes for breaking changes in CRD schemas or default behavior
- Back up CRD instances before upgrading (`kubectl get -o yaml`)
