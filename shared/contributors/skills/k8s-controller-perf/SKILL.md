---
name: k8s-controller-perf
description: Performance tuning for Kubernetes controllers — field indexers, predicate filters, cache optimization, work queue tuning, and observability
---

# Controller Performance

Performance tuning patterns for Kubernetes controllers. Covers field indexers for O(1) lookups, predicate filters to reduce reconciliation noise, cache optimization, work queue tuning, and observability.

## Field Indexers

### Why Indexers Matter

Without indexes, finding all resources that reference a Secret requires listing ALL resources and filtering client-side. With an index, the API server does an O(1) lookup.

```go
// WITHOUT index — O(n) list + filter
var allRoutes myv1.MyRouteList
_ = client.List(ctx, &allRoutes)
for _, route := range allRoutes.Items {
    if route.Spec.SecretRef.Name == secretName {
        // found it
    }
}

// WITH index — O(1) lookup
var matchingRoutes myv1.MyRouteList
_ = client.List(ctx, &matchingRoutes,
    client.MatchingFields{"spec.secretRef.name": secretName},
)
```

### Registering Indexes

Register indexes on the manager's field indexer before starting the manager:

```go
func SetupIndexes(mgr ctrl.Manager) error {
    // Index MyRoute by referenced secret name
    // NOTE: context.Background() is correct here — index registration happens
    // during manager setup (before Start), not during reconciliation.
    if err := mgr.GetFieldIndexer().IndexField(
        context.Background(),
        &myv1.MyRoute{},
        "spec.secretRef.name",
        func(obj client.Object) []string {
            route := obj.(*myv1.MyRoute)
            if route.Spec.SecretRef == nil {
                return nil
            }
            return []string{route.Spec.SecretRef.Name}
        },
    ); err != nil {
        return fmt.Errorf("indexing spec.secretRef.name: %w", err)
    }

    // Index by multiple references (e.g., all backends referenced by a route)
    if err := mgr.GetFieldIndexer().IndexField(
        context.Background(),
        &myv1.MyRoute{},
        "spec.rules.backendRefs.name",
        func(obj client.Object) []string {
            route := obj.(*myv1.MyRoute)
            var names []string
            for _, rule := range route.Spec.Rules {
                for _, ref := range rule.BackendRefs {
                    names = append(names, ref.Name)
                }
            }
            return names
        },
    ); err != nil {
        return fmt.Errorf("indexing backendRefs: %w", err)
    }

    return nil
}
```

### Index Scale

| Project | Index Count | Purpose |
|---------|:-----------:|---------|
| Envoy Gateway | 40+ | Cross-resource lookups for all Gateway API types |
| AI Gateway | 8 | Dependency chain lookups (Secret→BSP→ASB→Route) |

The number of indexes scales with the number of cross-resource relationships your controller needs to resolve.

### Index Naming Convention

Use the JSON path of the field being indexed:
- `spec.secretRef.name`
- `spec.rules.backendRefs.name`
- `spec.targetRefs.name`
- `metadata.annotations.my-annotation`

## Predicate Filters

### GenerationChangedPredicate

The most important predicate — skips reconciliation when only status or metadata changes (not spec):

```go
func (r *MyReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&myv1.MyResource{},
            builder.WithPredicates(predicate.GenerationChangedPredicate{}),
        ).
        Complete(r)
}
```

**Critical exception**: `GenerationChangedPredicate` does NOT work for Secrets. Kubernetes does not increment `.metadata.generation` when Secret data changes. AI Gateway's Secret controller explicitly avoids this predicate:

```go
// Secret controller — NO GenerationChangedPredicate
// because Secret data changes don't update .metadata.generation
builder.Watches(&corev1.Secret{}, handler.EnqueueRequestsFromMapFunc(r.findBSPsForSecret))

// CRD controllers — GenerationChangedPredicate is safe
builder.For(&myv1.MyCRD{},
    builder.WithPredicates(predicate.GenerationChangedPredicate{}),
)
```

### Custom Predicates

```go
// Only reconcile when specific annotations change
type annotationChangedPredicate struct {
    predicate.Funcs
    key string
}

func (p annotationChangedPredicate) Update(e event.UpdateEvent) bool {
    if e.ObjectOld == nil || e.ObjectNew == nil {
        return true
    }
    oldVal := e.ObjectOld.GetAnnotations()[p.key]
    newVal := e.ObjectNew.GetAnnotations()[p.key]
    return oldVal != newVal
}

// Only reconcile objects with a specific label
type labelPredicate struct {
    predicate.Funcs
    label string
}

func (p labelPredicate) Create(e event.CreateEvent) bool {
    _, exists := e.Object.GetLabels()[p.label]
    return exists
}

func (p labelPredicate) Update(e event.UpdateEvent) bool {
    _, exists := e.ObjectNew.GetLabels()[p.label]
    return exists
}
```

### Combining Predicates

```go
builder.WithPredicates(
    predicate.And(
        predicate.GenerationChangedPredicate{},
        labelPredicate{label: "managed-by-my-controller"},
    ),
)

builder.WithPredicates(
    predicate.Or(
        predicate.GenerationChangedPredicate{},
        annotationChangedPredicate{key: "force-reconcile"},
    ),
)
```

## Cache Optimization

### Disable Deep Copy (Escape Hatch — Use With Caution)

`UnsafeDisableDeepCopy` is an **escape hatch**, not a general recommendation. It eliminates allocations for cache reads but creates a dangerous shared-reference trap:

```go
mgr, err := ctrl.NewManager(cfg, ctrl.Options{
    Cache: cache.Options{
        DefaultUnsafeDisableDeepCopy: ptr.To(true),
    },
})
```

**Risks**:
- Objects returned from cache are **shared references** — mutating them corrupts the cache for all readers
- You **must** deep-copy before any modification: `obj := cached.DeepCopy()`
- Bugs are subtle and hard to reproduce (race conditions, intermittent corruption)
- Consider using this only after profiling confirms allocations are a bottleneck

**Prefer**: Targeted optimizations first (strip managed fields, label selectors, namespace filters). Only disable deep copy when profiling shows it's the dominant cost and all code paths are audited for mutation safety.

### Strip Managed Fields

Managed fields consume significant memory and are rarely needed by controllers:

```go
mgr, err := ctrl.NewManager(cfg, ctrl.Options{
    Cache: cache.Options{
        DefaultTransform: cache.TransformStripManagedFields(),
    },
})
```

### Label-Based Cache Filtering

Watch only relevant objects (e.g., only Pods managed by your controller):

```go
mgr, err := ctrl.NewManager(cfg, ctrl.Options{
    Cache: cache.Options{
        ByObject: map[client.Object]cache.ByObject{
            &corev1.Pod{}: {
                Label: labels.SelectorFromSet(labels.Set{
                    "app.kubernetes.io/managed-by": "my-controller",
                }),
            },
        },
    },
})
```

### Namespace-Scoped Cache

If your controller only operates in specific namespaces:

```go
mgr, err := ctrl.NewManager(cfg, ctrl.Options{
    Cache: cache.Options{
        DefaultNamespaces: map[string]cache.Config{
            "my-namespace": {},
        },
    },
})
```

## Work Queue Tuning

### Default Behavior

controller-runtime uses a rate-limited work queue with:
- **Exponential backoff**: 5ms initial, 1000s max (per-item)
- **Token bucket**: 10 events/second, burst 100

### Custom Rate Limiters

```go
import "k8s.io/client-go/util/workqueue"

ctrl.NewControllerManagedBy(mgr).
    WithOptions(controller.Options{
        RateLimiter: workqueue.NewTypedMaxOfRateLimiter(
            // Per-item exponential backoff
            workqueue.NewTypedItemExponentialFailureRateLimiter[reconcile.Request](
                100*time.Millisecond,  // base delay
                30*time.Second,        // max delay
            ),
            // Overall rate limit
            &workqueue.TypedBucketRateLimiter[reconcile.Request]{
                Limiter: rate.NewLimiter(rate.Limit(20), 200), // 20/s, burst 200
            },
        ),
    }).
    Complete(r)
```

### API Rate Limiting

Configure client-side rate limiting for the Kubernetes API server:

```go
cfg.QPS = 50    // Queries per second
cfg.Burst = 100 // Burst capacity
```

### Max Concurrent Reconciles

```go
ctrl.NewControllerManagedBy(mgr).
    WithOptions(controller.Options{
        MaxConcurrentReconciles: 5, // Default is 1
    }).
    Complete(r)
```

**Warning**: Increasing concurrency requires your reconciler to be thread-safe. Most reconcilers are designed for sequential processing.

## Metrics and Observability

### Built-in controller-runtime Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `controller_runtime_reconcile_total` | Counter | Total reconciliations by controller and result |
| `controller_runtime_reconcile_time_seconds` | Histogram | Reconciliation duration |
| `workqueue_depth` | Gauge | Current queue depth |
| `workqueue_adds_total` | Counter | Total items added to queue |
| `workqueue_retries_total` | Counter | Total retries |
| `workqueue_longest_running_processor_seconds` | Gauge | Longest running processor |

### Custom Metrics

```go
import "github.com/prometheus/client_golang/prometheus"

var (
    reconcileErrors = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "mycontroller_reconcile_errors_total",
            Help: "Total reconciliation errors by error type",
        },
        []string{"controller", "error_type"},
    )

    resourceCount = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "mycontroller_managed_resources",
            Help: "Number of managed resources by type",
        },
        []string{"resource_type"},
    )
)

func init() {
    metrics.Registry.MustRegister(reconcileErrors, resourceCount)
}
```

### Key Alerts

Monitor these signals for controller health:

| Signal | Alert Threshold | Indicates |
|--------|:--------------:|-----------|
| `workqueue_depth` sustained high | > 100 for 5min | Controller can't keep up |
| `reconcile_time_seconds` p99 | > 10s | Slow reconciliation |
| `reconcile_errors_total` rate | Increasing | Systematic failures |
| `workqueue_retries_total` rate | Increasing | Repeated failures |

## Common Performance Mistakes

| Mistake | Impact | Fix |
|---------|--------|-----|
| No field indexers | O(n) list-and-filter for lookups | Add `IndexField` for cross-resource refs |
| Missing `GenerationChangedPredicate` | Reconcile on every status update | Add predicate for CRD watchers |
| `GenerationChangedPredicate` on Secrets | Miss Secret data changes | Don't use this predicate for Secrets |
| Deep copy enabled for profiled bottleneck | Excessive allocations | `UnsafeDisableDeepCopy` as escape hatch after auditing mutation safety |
| Using `reflect.DeepEqual` for K8s objects | Fails for Quantity, Time types | `equality.Semantic.DeepEqual` from `k8s.io/apimachinery` |
| Watching all Pods cluster-wide | Huge cache, constant events | Label selector or namespace filter |
| Single concurrent reconcile for high-volume | Queue backs up | Increase `MaxConcurrentReconciles` |
| No rate limiting on API calls | API server throttling | Configure QPS/Burst |
| Managed fields in cache | Wasted memory | `TransformStripManagedFields` |
| Allocating inside reconcile loop | GC pressure | Pre-allocate, reuse buffers |
| Not monitoring queue depth | Silent degradation | Alert on sustained high depth |
