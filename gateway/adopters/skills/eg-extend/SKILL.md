---
name: eg-extend
description: Build custom Envoy Gateway extensions using ExtProc, Wasm, or Lua for request/response processing
---

# Envoy Gateway Extensions Builder

## Role

You help developers build custom extensions for Envoy Gateway. You guide them through choosing the right extension mechanism (ExtProc, Wasm, or Lua), scaffold the implementation, wire it to the gateway, and verify it works. You prioritize practical, working code over theory.

## Intake Interview

Before generating any code or configuration, ask the user these questions. Skip questions the user has already answered. Ask in a conversational tone, grouping related questions when it makes sense.

### Questions

1. **Purpose**: What do you need the extension to do?
   - Request transformation (add/modify/remove headers, rewrite body)
   - Custom authentication or authorization
   - Content inspection (PII redaction, compliance scanning)
   - Custom rate limiting logic
   - Response modification (add headers, transform body)
   - Request/response logging or auditing
   - AI Gateway functionality (model routing, token tracking)
   - Something else (describe it)

2. **Language preference**: What language do you prefer?
   - Go (recommended for ExtProc -- best ecosystem support)
   - Rust (recommended for Wasm -- best performance)
   - C++ (Wasm option -- lower level)
   - Python (ExtProc option -- easier prototyping)
   - TypeScript/JavaScript (ExtProc option)
   - Lua (inline scripting -- simplest for header manipulation)

3. **Processing scope**: Do you need to inspect or modify request/response bodies, or just headers?
   - Headers only (simplest, lowest latency)
   - Request body (requires body buffering or streaming)
   - Response body (requires response body buffering or streaming)
   - Both request and response bodies

4. **Latency tolerance**: What is your latency tolerance for the extension?
   - Minimal (< 1ms additional latency) -- consider Wasm (in-process)
   - Moderate (1-10ms) -- ExtProc works well
   - Flexible (10ms+) -- ExtProc with external service calls

5. **External dependencies**: Does the extension need to call external services?
   - Yes, a database (Redis, PostgreSQL, etc.)
   - Yes, an external API (REST, gRPC)
   - Yes, a cache
   - No, self-contained logic only

6. **Environment**: Is this for production or prototyping?
   - Production (needs health checks, scaling, failover, monitoring)
   - Prototyping / development (simplicity over resilience)

## Workflow

### Phase 1: Choose the Extension Mechanism

Based on the user's answers, recommend the appropriate mechanism and explain why.

#### Decision Matrix

| Requirement | ExtProc | Wasm | Lua |
|-------------|---------|------|-----|
| Any language | Yes | Rust, C++, TinyGo | Lua only |
| Call external services | Yes | No | No |
| Inspect/modify body | Yes (buffered or streamed) | Yes (buffered) | No |
| Lowest latency | No (gRPC overhead) | Yes (in-process) | Yes (in-process) |
| Production-ready | Yes (out-of-process, crash-safe) | Yes (sandboxed) | Limited |
| Debugging ease | High (standard debugging tools) | Medium (Wasm-specific tools) | High (simple scripts) |
| State between requests | Yes (in-memory or external) | Limited (per-request) | No |

**Recommendation rules:**
- If the user needs to call external services -> **ExtProc**
- If the user needs sub-millisecond latency and self-contained logic -> **Wasm**
- If the user only needs simple header manipulation for prototyping -> **Lua**
- If the user is unsure -> **ExtProc** (most flexible, safest for production)

### Phase 2: Scaffold the Extension

Generate a complete, working project based on the chosen mechanism.

#### ExtProc Scaffold (Go)

Generate a Go gRPC server implementing the Envoy External Processing API.

**Project structure:**
```
ext-proc-server/
  main.go
  processor.go
  go.mod
  go.sum
  Dockerfile
  k8s/
    deployment.yaml
    service.yaml
```

**main.go:**
```go
package main

import (
	"flag"
	"log"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	extprocpb "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
)

func main() {
	port := flag.String("port", "9002", "gRPC server port")
	flag.Parse()

	lis, err := net.Listen("tcp", ":"+*port)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	srv := grpc.NewServer()
	extprocpb.RegisterExternalProcessorServer(srv, &Processor{})

	// Health check for Kubernetes readiness/liveness probes
	healthSrv := health.NewServer()
	healthpb.RegisterHealthServer(srv, healthSrv)
	healthSrv.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)

	log.Printf("ExtProc server listening on :%s", *port)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
```

**processor.go:**
```go
package main

import (
	"io"
	"log"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extprocpb "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
)

// Processor implements the ExternalProcessor gRPC service.
type Processor struct {
	extprocpb.UnimplementedExternalProcessorServer
}

func (p *Processor) Process(stream extprocpb.ExternalProcessor_ProcessServer) error {
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		resp := &extprocpb.ProcessingResponse{}

		switch v := req.Request.(type) {
		case *extprocpb.ProcessingRequest_RequestHeaders:
			log.Printf("Processing request headers: %s %s",
				getHeader(v.RequestHeaders.Headers, ":method"),
				getHeader(v.RequestHeaders.Headers, ":path"))

			resp.Response = &extprocpb.ProcessingResponse_RequestHeaders{
				RequestHeaders: &extprocpb.HeadersResponse{
					Response: &extprocpb.CommonResponse{
						HeaderMutation: &extprocpb.HeaderMutation{
							SetHeaders: []*corev3.HeaderValueOption{
								{
									Header: &corev3.HeaderValue{
										// TODO: Replace with your custom header logic
										Key:      "x-processed-by",
										RawValue: []byte("ext-proc"),
									},
								},
							},
						},
					},
				},
			}

		case *extprocpb.ProcessingRequest_ResponseHeaders:
			resp.Response = &extprocpb.ProcessingResponse_ResponseHeaders{
				ResponseHeaders: &extprocpb.HeadersResponse{
					Response: &extprocpb.CommonResponse{
						HeaderMutation: &extprocpb.HeaderMutation{
							SetHeaders: []*corev3.HeaderValueOption{
								{
									Header: &corev3.HeaderValue{
										// TODO: Replace with your custom response header logic
										Key:      "x-ext-proc-processed",
										RawValue: []byte("true"),
									},
								},
							},
						},
					},
				},
			}

		case *extprocpb.ProcessingRequest_RequestBody:
			// TODO: Implement request body processing
			resp.Response = &extprocpb.ProcessingResponse_RequestBody{
				RequestBody: &extprocpb.BodyResponse{
					Response: &extprocpb.CommonResponse{},
				},
			}

		case *extprocpb.ProcessingRequest_ResponseBody:
			// TODO: Implement response body processing
			resp.Response = &extprocpb.ProcessingResponse_ResponseBody{
				ResponseBody: &extprocpb.BodyResponse{
					Response: &extprocpb.CommonResponse{},
				},
			}
		}

		if err := stream.Send(resp); err != nil {
			return err
		}
	}
}

func getHeader(headers *corev3.HeaderMap, name string) string {
	for _, h := range headers.GetHeaders() {
		if h.GetKey() == name {
			return string(h.GetRawValue())
		}
	}
	return ""
}
```

**go.mod:**
```
module ext-proc-server

go 1.22

require (
	github.com/envoyproxy/go-control-plane v0.13.4
	google.golang.org/grpc v1.70.0
)
```

**Dockerfile:**
```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o ext-proc-server .

FROM gcr.io/distroless/static-debian12
COPY --from=builder /app/ext-proc-server /ext-proc-server
ENTRYPOINT ["/ext-proc-server"]
```

**k8s/deployment.yaml and service.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ext-proc-server       # TODO: Rename to your extension name
  labels:
    app: ext-proc-server
spec:
  replicas: 2                 # TODO: Adjust for production
  selector:
    matchLabels:
      app: ext-proc-server
  template:
    metadata:
      labels:
        app: ext-proc-server
    spec:
      containers:
        - name: ext-proc
          image: your-registry/ext-proc-server:latest  # TODO: Replace with your image
          ports:
            - containerPort: 9002
              protocol: TCP
          readinessProbe:
            grpc:
              port: 9002
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            grpc:
              port: 9002
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: ext-proc-server       # TODO: Match the Deployment name
spec:
  selector:
    app: ext-proc-server
  ports:
    - port: 9002
      targetPort: 9002
      protocol: TCP
```

#### Wasm Scaffold (Rust)

Generate a Rust proxy-wasm project.

**Project structure:**
```
wasm-filter/
  Cargo.toml
  src/
    lib.rs
  Dockerfile
```

**Cargo.toml:**
```toml
[package]
name = "wasm-filter"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
proxy-wasm = "0.2"
log = "0.4"
```

**src/lib.rs:**
```rust
use proxy_wasm::traits::*;
use proxy_wasm::types::*;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> {
        Box::new(FilterRoot)
    });
}}

struct FilterRoot;

impl Context for FilterRoot {}

impl RootContext for FilterRoot {
    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }

    fn create_http_context(&self, _: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(Filter))
    }
}

struct Filter;

impl Context for Filter {}

impl HttpContext for Filter {
    fn on_http_request_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        // TODO: Implement your request header processing logic
        self.add_http_request_header("x-wasm-filter", "processed");
        Action::Continue
    }

    fn on_http_response_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        // TODO: Implement your response header processing logic
        self.add_http_response_header("x-wasm-filter-response", "processed");
        Action::Continue
    }

    // Uncomment for body processing:
    // fn on_http_request_body(&mut self, body_size: usize, end_of_stream: bool) -> Action {
    //     if !end_of_stream {
    //         return Action::Pause;
    //     }
    //     if let Some(body) = self.get_http_request_body(0, body_size) {
    //         // TODO: Process request body
    //     }
    //     Action::Continue
    // }
}
```

**Build and push as OCI image:**
```bash
# Build the Wasm binary
cargo build --target wasm32-wasip1 --release

# Create OCI image
cat > Dockerfile <<'EOF'
FROM scratch
COPY target/wasm32-wasip1/release/wasm_filter.wasm plugin.wasm
EOF

docker build -t your-registry/wasm-filter:v0.1.0 .
docker push your-registry/wasm-filter:v0.1.0
```

#### Lua Scaffold

For simple header manipulation, generate an inline Lua script or ConfigMap-based script.

**Inline Lua (simplest):**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: lua-header-filter  # TODO: Choose a descriptive name
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route         # TODO: Replace with your route name
  lua:
    - type: Inline
      inline: |
        function envoy_on_request(request_handle)
          -- TODO: Implement your request processing logic
          -- Example: Add a custom header
          request_handle:headers():add("x-lua-processed", "true")

          -- Example: Read and log a header
          local auth = request_handle:headers():get("authorization")
          if auth then
            request_handle:logInfo("Request has authorization header")
          end
        end

        function envoy_on_response(response_handle)
          -- TODO: Implement your response processing logic
          response_handle:headers():add("x-lua-response", "processed")
        end
```

**ConfigMap-based Lua (better for version control):**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lua-filter-script  # TODO: Choose a descriptive name
data:
  lua: |
    function envoy_on_request(request_handle)
      -- TODO: Implement your logic
      request_handle:headers():add("x-lua-processed", "true")
    end

    function envoy_on_response(response_handle)
      -- TODO: Implement your logic
      response_handle:headers():add("x-lua-response", "processed")
    end
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: lua-filter-policy
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route         # TODO: Replace
  lua:
    - type: ValueRef
      valueRef:
        name: lua-filter-script
        kind: ConfigMap
        group: v1
```

### Phase 3: Configure EnvoyExtensionPolicy

Wire the extension to the Gateway or Route using EnvoyExtensionPolicy. Use the `/eg-extension` skill for the full configuration.

#### ExtProc EnvoyExtensionPolicy

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: ext-proc-policy  # TODO: Choose a descriptive name
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute          # Target: Gateway, HTTPRoute, or Backend
      name: my-route           # TODO: Replace with your target resource name
  extProc:
    - backendRefs:
        - name: ext-proc-server  # Must match the Service name
          port: 9002
      processingMode:
        request: {}              # Send request headers to processor
        # Uncomment for body processing:
        # request:
        #   body: Buffered       # Or: Streamed
        response: {}             # Send response headers to processor
        # response:
        #   body: Buffered       # Or: Streamed
      messageTimeout: 1s         # TODO: Tune based on processor latency
      failOpen: false            # TODO: Set to true for non-critical extensions
```

#### Wasm EnvoyExtensionPolicy

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: wasm-policy
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route           # TODO: Replace
  wasm:
    - name: my-wasm-filter
      rootID: my_root_id       # Must match the root_id in your Wasm code
      code:
        type: Image
        image:
          url: your-registry/wasm-filter:v0.1.0  # TODO: Replace
          # pullSecretRef:
          #   name: my-registry-secret  # For private registries
      failOpen: false
```

### Phase 4: Test the Extension

Provide curl commands to verify the extension is working.

```bash
# Get the Gateway address
export GATEWAY_HOST=$(kubectl get gateway <gateway-name> -o jsonpath='{.status.addresses[0].value}')

# Test without the extension (baseline)
curl -v http://$GATEWAY_HOST/test-path \
  -H "Host: app.example.com"

# After applying the extension policy, verify the custom headers appear
curl -v http://$GATEWAY_HOST/test-path \
  -H "Host: app.example.com" 2>&1 | grep -i "x-processed-by\|x-ext-proc\|x-wasm-filter\|x-lua"
```

For ExtProc, also check the processor logs:

```bash
kubectl logs -l app=ext-proc-server -f
```

Verify the EnvoyExtensionPolicy is accepted:

```bash
kubectl get envoyextensionpolicy <policy-name> -o yaml
# Check status.conditions for Accepted: True
```

### Phase 5: Production Considerations

For production deployments, apply these hardening steps:

#### ExtProc Production Hardening

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: ext-proc-production
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  extProc:
    - backendRefs:
        - name: ext-proc-server
          port: 9002
      processingMode:
        request: {}
        response: {}
      # Tune timeout for your processor's actual latency profile
      messageTimeout: 500ms          # TODO: Set based on p99 latency + buffer
      # failOpen: decide based on criticality
      # - false: requests fail if processor is down (use for auth, compliance)
      # - true: requests bypass processor if it is down (use for logging, metrics)
      failOpen: false                # TODO: Set based on your requirements
```

**Scaling the ExtProc service:**
- Set replicas >= 2 for availability
- Add HPA based on CPU or gRPC connection count
- Set resource requests and limits
- Configure PodDisruptionBudget

**Health checks:**
- Use gRPC health checking protocol (already included in the scaffold)
- Configure readiness and liveness probes in the Deployment

#### Wasm Production Considerations

- Pin the OCI image tag to a specific version (never use `latest`)
- Provide the `sha256` checksum for HTTP-loaded Wasm binaries
- Test Wasm performance under load -- in-process execution means bugs can affect Envoy stability
- Monitor Envoy memory usage -- Wasm modules consume memory within the Envoy process

#### Lua Limitations for Production

- Lua extensions are single-threaded within the Envoy worker thread
- No persistent state between requests
- Limited API surface (headers only, no body access)
- Best suited for simple, low-risk header manipulation
- For anything more complex, migrate to ExtProc or Wasm

## Output Requirements

Generate all artifacts needed for a working extension:

1. Complete source code for the chosen mechanism
2. Build instructions (Dockerfile, Cargo.toml, go.mod)
3. Kubernetes manifests (Deployment, Service for ExtProc)
4. EnvoyExtensionPolicy connecting the extension to the Gateway/Route
5. Test commands (curl examples showing before/after behavior)
6. For production: scaling, health check, and monitoring guidance

## Guidelines

- Always start with ExtProc if the user is unsure -- it is the most flexible and safest option.
- Use `gateway.envoyproxy.io/v1alpha1` for all Envoy Gateway extension CRDs.
- Include TODO comments in code and YAML for values the user must customize.
- For ExtProc, always include gRPC health checks in the scaffold.
- For Wasm, always specify `rootID` and explain how it maps to the Wasm code.
- For Lua, warn about limitations upfront and suggest migration path to ExtProc for complex use cases.
- EnvoyExtensionPolicy must be in the same namespace as the target resource.
