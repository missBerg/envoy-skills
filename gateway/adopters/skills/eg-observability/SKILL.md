---
name: eg-observability
description: Configure access logging, metrics, and distributed tracing for Envoy Gateway
arguments:
  - name: Feature
    description: "Feature to configure: logging, metrics, tracing, all (default: all)"
    required: false
---

# Envoy Gateway Observability

Generate EnvoyProxy telemetry configuration for access logging, metrics, and distributed
tracing. Also covers Envoy Gateway controller logging and proxy debug logging. All
proxy-level telemetry is configured via the EnvoyProxy CRD under `spec.telemetry`.

## Instructions

### Step 1: Create the EnvoyProxy Resource

The EnvoyProxy resource holds all telemetry configuration. It is linked to your
GatewayClass via `parametersRef` or to an individual Gateway via `infrastructure.parametersRef`.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: observability-config  # TODO: choose a descriptive name
  namespace: envoy-gateway-system
spec:
  telemetry:
    # Sections below configure accessLog, metrics, and tracing.
    # Include only the sections you need.
```

#### Link to GatewayClass (applies to all Gateways)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: observability-config
    namespace: envoy-gateway-system
```

#### Link to a specific Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  infrastructure:
    parametersRef:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: observability-config
  listeners:
    - name: http
      protocol: HTTP
      port: 80
```

### Step 2: Access Logging

Configure via `spec.telemetry.accessLog`. By default, Envoy Gateway sends a default
format to stdout. When you define custom settings, the default is replaced.

Reference: EGTM-016 recommends configuring access logging to detect unauthorized
access and enable incident response.

#### File-based access log (JSON format -- recommended for machine parsing)

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: observability-config
  namespace: envoy-gateway-system
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: JSON
            json:
              start_time: "%START_TIME%"
              method: "%REQ(:METHOD)%"
              path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
              protocol: "%PROTOCOL%"
              response_code: "%RESPONSE_CODE%"
              response_flags: "%RESPONSE_FLAGS%"
              bytes_received: "%BYTES_RECEIVED%"
              bytes_sent: "%BYTES_SENT%"
              duration: "%DURATION%"
              upstream_host: "%UPSTREAM_HOST%"
              x_forwarded_for: "%REQ(X-FORWARDED-FOR)%"
              user_agent: "%REQ(USER-AGENT)%"
              request_id: "%REQ(X-REQUEST-ID)%"
              authority: "%REQ(:AUTHORITY)%"
          sinks:
            - type: File
              file:
                path: /dev/stdout  # TODO: change to a file path if not using stdout
```

#### File-based access log (text format)

```yaml
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: Text
            text: |
              [%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%" %RESPONSE_CODE% %RESPONSE_FLAGS% %BYTES_RECEIVED% %BYTES_SENT% %DURATION% "%REQ(X-FORWARDED-FOR)%" "%REQ(USER-AGENT)%" "%REQ(X-REQUEST-ID)%" "%REQ(:AUTHORITY)%" "%UPSTREAM_HOST%"
          sinks:
            - type: File
              file:
                path: /dev/stdout
```

#### OpenTelemetry access log sink

```yaml
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: Text
            text: |
              [%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%" %RESPONSE_CODE% %RESPONSE_FLAGS% %BYTES_RECEIVED% %BYTES_SENT% %DURATION% "%REQ(X-FORWARDED-FOR)%" "%REQ(USER-AGENT)%" "%REQ(X-REQUEST-ID)%" "%REQ(:AUTHORITY)%" "%UPSTREAM_HOST%"
          sinks:
            - type: OpenTelemetry
              openTelemetry:
                host: otel-collector.monitoring.svc.cluster.local  # TODO: your OTel collector host
                port: 4317                                          # TODO: your OTel collector gRPC port
                resources:
                  k8s.cluster.name: "my-cluster"  # TODO: set your cluster name
```

#### gRPC Access Log Service (ALS) sink

```yaml
spec:
  telemetry:
    accessLog:
      settings:
        - sinks:
            - type: ALS
              als:
                backendRefs:
                  - name: als-service         # TODO: your ALS service name
                    namespace: monitoring      # TODO: your ALS service namespace
                    port: 9000
                type: HTTP  # HTTP or TCP
```

#### Access log filtering with CEL expressions

Filter logs to reduce volume -- for example, only log errors or specific paths:

```yaml
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: JSON
            json:
              method: "%REQ(:METHOD)%"
              path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
              response_code: "%RESPONSE_CODE%"
              duration: "%DURATION%"
          # Only log requests that resulted in errors (4xx/5xx)
          matches:
            - "response.code >= 400"
          sinks:
            - type: File
              file:
                path: /dev/stdout
```

#### Route vs. Listener access log types

By default, access log settings apply to all Routes. You can separate Route-level and
Listener-level logging:

```yaml
spec:
  telemetry:
    accessLog:
      settings:
        - type: Route  # Re-enable default access log for matched routes
        - type: Listener  # Custom log for listener-level events (e.g., TLS failures)
          format:
            type: Text
            text: |
              [%START_TIME%] %DOWNSTREAM_REMOTE_ADDRESS% %RESPONSE_FLAGS% %BYTES_RECEIVED% %BYTES_SENT% %DOWNSTREAM_TRANSPORT_FAILURE_REASON%
          sinks:
            - type: File
              file:
                path: /dev/stdout
```

### Step 3: Metrics

Configure via `spec.telemetry.metrics`. Prometheus metrics are enabled by default on
the Envoy admin port (19001) at `/stats/prometheus`.

#### Prometheus metrics (default -- already enabled)

To verify Prometheus is working:
```bash
# Port-forward to an Envoy proxy pod
kubectl port-forward -n envoy-gateway-system pod/<envoy-pod> 19001:19001
curl localhost:19001/stats/prometheus | head -50
```

#### Disable Prometheus (if using only OpenTelemetry)

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: observability-config
  namespace: envoy-gateway-system
spec:
  telemetry:
    metrics:
      prometheus:
        disable: true
```

#### OpenTelemetry metrics sink

```yaml
spec:
  telemetry:
    metrics:
      sinks:
        - type: OpenTelemetry
          openTelemetry:
            host: otel-collector.monitoring.svc.cluster.local  # TODO: your OTel collector host
            port: 4317                                          # TODO: your OTel collector gRPC port
```

#### Enable additional metric features

```yaml
spec:
  telemetry:
    metrics:
      prometheus:
        disable: false
      # Enable virtual host stats for per-vhost metrics
      enableVirtualHostStats: true
      # Enable per-endpoint stats (use with caution -- high cardinality)
      # enablePerEndpointStats: true
      # Enable request/response size histograms
      # enableRequestResponseSizesStats: true
      sinks:
        - type: OpenTelemetry
          openTelemetry:
            host: otel-collector.monitoring.svc.cluster.local
            port: 4317
```

#### Prometheus ServiceMonitor for auto-discovery

If you use the Prometheus Operator, create a PodMonitor to scrape Envoy proxy pods:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: envoy-proxy-metrics
  namespace: monitoring  # TODO: your monitoring namespace
  labels:
    app.kubernetes.io/name: envoy-proxy
spec:
  namespaceSelector:
    matchNames:
      - envoy-gateway-system  # TODO: namespace where Envoy proxy pods run
  selector:
    matchLabels:
      gateway.envoyproxy.io/owning-gateway-name: eg  # TODO: your Gateway name
  podMetricsEndpoints:
    - port: metrics
      path: /stats/prometheus
      interval: 15s  # TODO: adjust scrape interval
```

**Key metrics to monitor:**
- `envoy_http_downstream_rq_total` -- total request count
- `envoy_http_downstream_rq_xx` -- response code classes (2xx, 4xx, 5xx)
- `envoy_cluster_upstream_rq_time` -- upstream request latency
- `envoy_http_downstream_cx_active` -- active downstream connections
- `envoy_cluster_upstream_cx_active` -- active upstream connections
- `envoy_cluster_membership_healthy` -- healthy backend endpoints
- `envoy_cluster_upstream_rq_retry` -- retry count

### Step 4: Distributed Tracing

Configure via `spec.telemetry.tracing`. Envoy Gateway supports OpenTelemetry, Zipkin,
and Datadog as tracing providers.

#### OpenTelemetry tracing

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: observability-config
  namespace: envoy-gateway-system
spec:
  telemetry:
    tracing:
      # Sampling rate: percentage of requests to trace.
      # Use 1-10 for production, 100 for staging/debugging.
      samplingRate: 1  # TODO: adjust sampling rate (1-100)
      provider:
        type: OpenTelemetry
        backendRefs:
          - name: otel-collector        # TODO: your OTel collector service name
            namespace: monitoring       # TODO: your OTel collector namespace
            port: 4317                  # gRPC port for OTLP
      # Custom tags added to every span
      customTags:
        "k8s.cluster.name":
          type: Literal
          literal:
            value: "my-cluster"  # TODO: set your cluster name
        "k8s.pod.name":
          type: Environment
          environment:
            name: ENVOY_POD_NAME
            defaultValue: "-"
        "k8s.namespace.name":
          type: Environment
          environment:
            name: ENVOY_POD_NAMESPACE
            defaultValue: "envoy-gateway-system"
        # Tag spans with a request header value
        "x-request-source":
          type: RequestHeader
          requestHeader:
            name: X-Request-Source
            defaultValue: "unknown"
```

#### Zipkin tracing

```yaml
spec:
  telemetry:
    tracing:
      samplingRate: 10
      provider:
        type: Zipkin
        backendRefs:
          - name: zipkin-collector     # TODO: your Zipkin service name
            namespace: monitoring
            port: 9411
        zipkin:
          enable128BitTraceId: true
```

#### Datadog tracing

```yaml
spec:
  telemetry:
    tracing:
      samplingRate: 10
      provider:
        type: Datadog
        backendRefs:
          - name: datadog-agent        # TODO: your Datadog agent service name
            namespace: monitoring
            port: 8126
```

**Trace context propagation:** Envoy automatically propagates W3C Trace Context
headers (`traceparent`, `tracestate`). Ensure your backend services also propagate
these headers to maintain end-to-end traces.

### Step 5: Envoy Gateway Controller Logging

To configure logging for the Envoy Gateway control plane itself, update the
EnvoyGateway configuration ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-gateway-config
  namespace: envoy-gateway-system
data:
  envoy-gateway.yaml: |
    apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: EnvoyGateway
    provider:
      type: Kubernetes
    gateway:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
    logging:
      level:
        default: info     # TODO: set to debug for troubleshooting
        # Component-specific levels:
        # gateway-api: debug
        # provider: debug
        # infrastructure: debug
    # Control plane metrics
    telemetry:
      metrics:
        prometheus:
          disable: false
        # Send control plane metrics to OTel collector:
        # sinks:
        #   - type: OpenTelemetry
        #     openTelemetry:
        #       host: otel-collector.monitoring.svc.cluster.local
        #       port: 4317
        #       protocol: grpc
```

After updating the ConfigMap, restart the controller:
```bash
kubectl rollout restart deployment envoy-gateway -n envoy-gateway-system
```

### Step 6: Proxy Debug Logging

To enable debug logging on specific Envoy Proxy components for troubleshooting,
use the EnvoyProxy resource:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: debug-proxy
  namespace: envoy-gateway-system
spec:
  logging:
    level:
      default: warn       # Base level for all components
      # Enable debug for specific components:
      # http: debug
      # router: debug
      # connection: debug
      # upstream: debug
```

You can also change log levels at runtime via the Envoy admin interface:
```bash
kubectl port-forward -n envoy-gateway-system pod/<envoy-pod> 19001:19001
# Set a component to debug level
curl -X POST "localhost:19001/logging?http=debug"
# Reset to warning
curl -X POST "localhost:19001/logging?http=warning"
```

## Checklist

- [ ] EnvoyProxy resource is created in the correct namespace
- [ ] EnvoyProxy is linked via GatewayClass `parametersRef` or Gateway `infrastructure.parametersRef`
- [ ] Access logging format includes at minimum: method, path, response code, duration, upstream host
- [ ] Access log sinks are configured (File and/or OpenTelemetry)
- [ ] Prometheus metrics endpoint is enabled (default) or explicitly disabled if using only OTel
- [ ] OpenTelemetry collector is deployed and accessible from the Envoy proxy pods
- [ ] Tracing sampling rate is appropriate: 1-10% for production, 100% for staging
- [ ] Custom trace tags include cluster name and pod metadata for correlation
- [ ] PodMonitor or ServiceMonitor is configured if using Prometheus Operator
- [ ] Grafana dashboards are set up for key metrics (request rate, latency, error rate)
- [ ] Controller log level is set to `info` in production, `debug` only for troubleshooting
- [ ] Verify access logs appear: `kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg`
- [ ] Verify metrics: `curl localhost:19001/stats/prometheus` via port-forward
- [ ] Verify traces appear in your tracing backend (Jaeger, Tempo, Zipkin, Datadog)
