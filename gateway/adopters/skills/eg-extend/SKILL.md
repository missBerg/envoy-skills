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
   - Request/response transformation (headers, body rewriting)
   - Custom authentication, authorization, or content inspection
   - Custom rate limiting, logging/auditing, or AI Gateway functionality
   - Something else (describe it)

2. **Language preference**: What language do you prefer?
   - Go (recommended for ExtProc), Rust (recommended for Wasm), Lua (simplest for headers)
   - Python, TypeScript, C++ (ExtProc or Wasm options)

3. **Processing scope**: Headers only, request body, response body, or both bodies?

4. **Latency tolerance**: Minimal (< 1ms, consider Wasm), moderate (1-10ms, ExtProc), or flexible (10ms+)?

5. **External dependencies**: Does the extension need to call external services (database, API, cache)?

6. **Environment**: Production (health checks, scaling, failover) or prototyping?

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

		// TODO: Add cases for ResponseHeaders, RequestBody, ResponseBody as needed
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
          image: your-registry/ext-proc-server:latest  # TODO: Replace
          ports:
            - containerPort: 9002
          readinessProbe:
            grpc:
              port: 9002
          livenessProbe:
            grpc:
              port: 9002
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
  name: ext-proc-server
spec:
  selector:
    app: ext-proc-server
  ports:
    - port: 9002
      targetPort: 9002
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
    // TODO: Add on_http_request_body / on_http_response_body for body processing
}
```

**Build and push as OCI image:**
```bash
cargo build --target wasm32-wasip1 --release
# Package as OCI image (Dockerfile: FROM scratch, COPY target/wasm32-wasip1/release/wasm_filter.wasm plugin.wasm)
docker build -t your-registry/wasm-filter:v0.1.0 .  # TODO: Replace registry
docker push your-registry/wasm-filter:v0.1.0
```

#### Lua Scaffold

For simple header manipulation, generate an inline Lua script:
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

For version control, use a ConfigMap with `type: ValueRef` instead of inline Lua.

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

```bash
# Get the Gateway address and test
export GATEWAY_HOST=$(kubectl get gateway <gateway-name> -o jsonpath='{.status.addresses[0].value}')
curl -v http://$GATEWAY_HOST/test-path -H "Host: app.example.com" 2>&1 | grep -i "x-processed-by\|x-ext-proc\|x-wasm-filter\|x-lua"

# For ExtProc, check processor logs
kubectl logs -l app=ext-proc-server -f

# Verify the EnvoyExtensionPolicy is accepted
kubectl get envoyextensionpolicy <policy-name> -o jsonpath='{.status.conditions}'
```

### Phase 5: Production Considerations

For production deployments, apply these hardening steps:

#### ExtProc Production Hardening

Tune the EnvoyExtensionPolicy from Phase 3 for production:
- Set `messageTimeout` based on your processor's p99 latency + buffer (e.g., `500ms`)
- Set `failOpen: false` for critical extensions (auth, compliance), `true` for non-critical (logging)
- Set Deployment replicas >= 2, add HPA based on CPU or gRPC connection count
- Configure resource requests/limits and PodDisruptionBudget
- gRPC health checks are already included in the scaffold

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

Generate: source code, build instructions (Dockerfile, Cargo.toml, go.mod), Kubernetes manifests, EnvoyExtensionPolicy, test commands, and production guidance.

## Guidelines

- Always start with ExtProc if the user is unsure -- it is the most flexible and safest option.
- Use `gateway.envoyproxy.io/v1alpha1` for all Envoy Gateway extension CRDs.
- Include TODO comments in code and YAML for values the user must customize.
- For ExtProc, always include gRPC health checks in the scaffold.
- For Wasm, always specify `rootID` and explain how it maps to the Wasm code.
- For Lua, warn about limitations upfront and suggest migration path to ExtProc for complex use cases.
- EnvoyExtensionPolicy must be in the same namespace as the target resource.
