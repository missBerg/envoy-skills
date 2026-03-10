---
name: aigw-contrib-go-style
description: Go best practices as demonstrated by lead maintainer @mathetake — performance patterns, JSON handling, error style, naming, streaming, and test structure that determine PR acceptance
---

# Go Style Guide (AI Gateway)

This guide captures the Go coding patterns enforced by the lead maintainer (@mathetake). Following these patterns is the single biggest factor in getting PRs accepted on the first or second review cycle.

## Performance Patterns

These are the most common reasons PRs get rejected.

### No Allocations Inside Loops

Construct maps, slices, and reusable objects **once** outside the loop:

```go
// BAD — allocates a new map every iteration
for _, item := range items {
    m := make(map[string]string)
    // ...
}

// GOOD — allocate once, reuse or reset
m := make(map[string]string, len(items))
for _, item := range items {
    m[item.Key] = item.Value
}
```

### Pass Large Structs by Pointer

Use index-based loop access (`&items[i]`) over value-copy range:

```go
// BAD — copies each element
for _, item := range items {
    process(item) // item is a copy
}

// GOOD — pointer to original
for i := range items {
    process(&items[i])
}
```

### Return Pointers from Builder Functions

```go
// BAD
func newFlags() flags { return flags{} }

// GOOD
func newFlags() *flags { return &flags{} }
```

### Pre-Allocate Resources Once

HTTP clients, JSON decoders, byte buffers — create once, not per-request:

```go
// BAD — created per request
func (t *translator) handleRequest(body []byte) {
    dec := json.NewDecoder(bytes.NewReader(body))
    // ...
}

// GOOD — created once in constructor
type translator struct {
    buf *bytes.Buffer // reused across requests
}
```

## JSON Handling

This project has strict JSON library requirements.

### Never Use encoding/json

The linter enforces this. Use the project's internal wrapper:

```go
// BAD — will fail lint
import "encoding/json"

// GOOD
import "github.com/envoyproxy/ai-gateway/internal/json"
```

The `internal/json` package wraps sonic for high-performance JSON operations.

### Use gjson for Reading JSON Fields

Especially for discriminated unions with manual `UnmarshalJSON`:

```go
import "github.com/tidwall/gjson"

func (m *myType) UnmarshalJSON(data []byte) error {
    typeField := gjson.GetBytes(data, "type").String()
    switch typeField {
    case "text":
        // unmarshal as text type
    case "image":
        // unmarshal as image type
    }
    return nil
}
```

### Use sjson for Mutating JSON Bytes

Never deserialize to `map[string]interface{}` just to change a field:

```go
import "github.com/tidwall/sjson"

// BAD — allocates intermediate map
var m map[string]interface{}
json.Unmarshal(body, &m)
m["model"] = "new-model"
result, _ := json.Marshal(m)

// GOOD — mutate bytes directly
result, _ := sjson.SetBytes(body, "model", "new-model")
```

## Error Handling

### Always Wrap with Context

```go
// BAD
return err

// GOOD
return fmt.Errorf("translating request from %s to %s: %w", src, tgt, err)
```

### Few Broad Sentinel Errors

Use 1-2 broad error types, not fine-grained error enums:

```go
// BAD — too many sentinel errors
var (
    ErrInvalidModel    = errors.New("invalid model")
    ErrInvalidSchema   = errors.New("invalid schema")
    ErrMissingField    = errors.New("missing field")
    ErrUnsupportedType = errors.New("unsupported type")
)

// GOOD — broad categories
var (
    ErrInvalidRequest = errors.New("invalid request")
)
```

### Silent Continue for Non-Critical Errors

In streaming paths, non-critical parse errors can be silently skipped:

```go
for _, chunk := range chunks {
    translated, err := translateChunk(chunk)
    if err != nil {
        continue // non-critical — skip malformed chunk
    }
    out = append(out, translated...)
}
```

## Naming Conventions

| Context | Convention | Examples |
|---------|-----------|----------|
| Local variables | Short, 1-2 chars or abbreviated | `r`, `dec`, `buf`, `msg`, `b` |
| Exported types | Descriptive PascalCase | `BackendSecurityPolicy`, `AIServiceBackend` |
| Unexported types | Descriptive camelCase | `anthropicToAWSAnthropicTranslator` |
| Test expected values | `exp` prefix | `expPath`, `expStatus`, `expResponseBody` |
| Package aliases (API schemas) | `schema` suffix | `anthropicschema`, `cohereschema` |
| Panicking functions | `must` prefix | `mustMarshal`, `mustParse` |
| Conditional-action functions | `maybe` prefix | `maybeRotate`, `maybeRefresh` |
| Import aliases (K8s APIs) | Abbreviated | `aigv1a1`, `gwapiv1`, `egv1a1`, `metav1` |

## Streaming / SSE Construction

### Build SSE by Direct Byte Append

No SSE libraries — use raw byte operations:

```go
// Package-level constants
var (
    sseDataPrefix  = []byte("data: ")
    sseLineEnd     = []byte("\n\n")
    sseDoneMessage = []byte("data: [DONE]\n\n")
)

// Build output by appending
func buildSSELine(out *[]byte, data []byte) {
    *out = append(*out, sseDataPrefix...)
    *out = append(*out, data...)
    *out = append(*out, sseLineEnd...)
}
```

### Buffered Incremental Parsing

For AWS EventStream or partial SSE chunks, maintain state across calls:

```go
type streamState struct {
    buffered []byte // incomplete data from previous call
}

func (s *streamState) processChunk(chunk []byte) ([]byte, error) {
    s.buffered = append(s.buffered, chunk...)
    // Parse complete events from s.buffered
    // Leave incomplete data in s.buffered for next call
}
```

### Always Handle Both Paths

Every translator must handle streaming and non-streaming:

```go
func (t *translator) translateResponse(body []byte, streaming bool) ([]byte, error) {
    if streaming {
        return t.translateStreamChunk(body)
    }
    return t.translateFullResponse(body)
}
```

## Code Organization

### Extract Shared Logic (DRY)

Even moderate duplication should be extracted:

```go
// BAD — duplicated in 3 translators
func (t *openaiToAWS) translateRequest(body []byte) {
    model := gjson.GetBytes(body, "model").String()
    body, _ = sjson.DeleteBytes(body, "stream_options")
    // ...
}

// GOOD — shared helper
func extractAndCleanModel(body []byte) (string, []byte) {
    model := gjson.GetBytes(body, "model").String()
    body, _ = sjson.DeleteBytes(body, "stream_options")
    return model, body
}
```

### Test-Only Code in _test.go

Move helpers and constants used only in tests to test files:

```go
// internal/extproc/translators/helpers_test.go
func requireJSONEqual(t *testing.T, exp, actual []byte) {
    t.Helper()
    // ...
}
```

### Comments Explain Why, Not What

```go
// BAD
// Set the model name
body, _ = sjson.SetBytes(body, "model", newModel)

// GOOD
// Azure requires the deployment name, not the model name
body, _ = sjson.SetBytes(body, "model", deploymentName)
```

### Lint Suppression with Specific Linter

```go
//nolint:gocritic // intentional value copy for test isolation
```

## Named Return Values

Use for functions with 3+ return values (common in translators):

```go
// GOOD — named returns enable bare return on error paths
func (t *translator) translate(body []byte) (translated []byte, model string, err error) {
    model = gjson.GetBytes(body, "model").String()
    if model == "" {
        err = fmt.Errorf("missing model field")
        return
    }
    translated, err = t.doTranslate(body, model)
    return
}
```

## PR Hygiene

### Single-Purpose PRs Only

Never conflate unrelated changes in a single PR:

```
# BAD — PR title: "fix translation + update CI + add new test helper"
# GOOD — three separate PRs
```

### Remove Dead Code

Do not comment out code — delete it. Git preserves history:

```go
// BAD
// func oldTranslator() { ... }

// GOOD — just delete it
```

### Self-Annotate Large Diffs

For large PRs, add comments on the diff explaining sections to reviewers.

## Test Conventions

| Pattern | Convention |
|---------|-----------|
| Assertions | `require` for fatal (test cannot continue), `assert` for non-fatal |
| Context | `t.Context()` — never `context.Background()` in tests |
| Goroutine leaks | `goleak.VerifyNone(t)` in `TestMain` |
| Expected values | `exp` prefix: `expBody`, `expStatus`, `expHeaders` |
| Table-driven tests | Use `name` field, `t.Run(tc.name, ...)` |
| Test files | `_test.go` suffix, same package |
