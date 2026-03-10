---
name: k8s-controller-reconcile
description: Idempotent reconciliation patterns for Kubernetes controllers — event handling, error classification, requeue semantics, status management, and ownership
---

# Kubernetes Controller Reconciliation

Core reconciliation patterns for building reliable Kubernetes controllers with controller-runtime. Draws from battle-tested patterns in Envoy Gateway and Envoy AI Gateway.

## Level-Triggered Reconciliation

The golden rule: reconciliation must be **idempotent and level-triggered**, not edge-triggered. Your `Reconcile()` function should derive the desired state from the current world state, not from the event that triggered it.

```go
func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // 1. Fetch the current state of the object
    var obj myv1.MyResource
    if err := r.client.Get(ctx, req.NamespacedName, &obj); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 2. Compute desired state from CURRENT world state (not from the event)
    desired := r.computeDesiredState(ctx, &obj)

    // 3. Compare and reconcile
    if err := r.applyDesiredState(ctx, &obj, desired); err != nil {
        return ctrl.Result{}, fmt.Errorf("applying desired state: %w", err)
    }

    return ctrl.Result{}, nil
}
```

Why this matters:
- Events can be lost, duplicated, or arrive out of order
- The work queue deduplicates — multiple events for the same key collapse into one reconcile
- Your function may be called without any event (periodic re-sync)

## Reconciler Architecture Patterns

### Pattern A: Per-CRD Controllers (Recommended)

Each CRD has its own controller with well-scoped responsibility. This is the standard approach recommended by Kubebuilder and Operator SDK. Cross-resource dependencies are communicated via typed event channels or mapper functions.

```go
// Channel-based event propagation ("sink" pattern) — AI Gateway
bspCh := make(chan event.GenericEvent, 100)
asbCh := make(chan event.GenericEvent, 100)
routeCh := make(chan event.GenericEvent, 100)

// Dependency chain:
// Secret → BSP → AIServiceBackend → AIGatewayRoute → Gateway
secretCtrl.SetupWithManager(mgr, bspCh)       // outputs to BSP channel
bspCtrl.SetupWithManager(mgr, bspCh, asbCh)   // reads BSP, outputs to ASB
asbCtrl.SetupWithManager(mgr, asbCh, routeCh) // reads ASB, outputs to Route
routeCtrl.SetupWithManager(mgr, routeCh)       // terminal "sink"
```

**Important**: Size event channels appropriately and handle backpressure. If a channel is full, the send will block (buffered) or drop (select/default). Monitor channel utilization in production.

**When to use**: When resources have clear dependency chains and each controller has well-scoped responsibility. This is the preferred pattern for new controllers.

### Envoy Gateway's Mega-Reconciler: A Deliberate Design Decision

Envoy Gateway funnels 30+ resource types into a single reconciler via an `enqueueClass` mapping function. While Kubebuilder and Operator SDK recommend per-CRD controllers as the default, **EG's approach is a deliberate architectural decision** driven by specific requirements:

**Why EG uses a mega-reconciler**:
1. **Atomic IR translation**: EG's pipeline is `Gateway API resources → Intermediate Representation (IR) → xDS`. Building the IR requires seeing all resources (Gateways, HTTPRoutes, SecurityPolicies, BackendTrafficPolicies, etc.) simultaneously to produce a consistent xDS configuration. Per-CRD controllers would need complex cross-controller coordination to achieve the same atomicity.
2. **Cross-resource consistency**: The Gateway API spec only guarantees consistency at the single-resource level. EG handles broken links, conflict resolution (oldest timestamp wins), and policy attachment across 30+ types in one atomic pass.
3. **Deterministic xDS generation**: A single reconciliation pass ensures all replicas produce identical xDS configs from the same resource state, avoiding configuration drift between Envoy proxy instances.

**Trade-offs to be aware of**:
- **Blast radius**: Any change to any watched type triggers a full state rebuild
- **Scalability**: One hot reconciler processes all events serially
- **Debugging**: Harder to trace which resource change caused specific behavior
- **Testing**: Cannot test one resource type's reconciliation in isolation

**Guidance**: Do not attempt to decompose EG's mega-reconciler without understanding the IR translation pipeline — the coupling is intentional. For new Kubernetes control plane projects where resources don't need atomic cross-type translation, prefer per-CRD controllers.

## Event Handling

### Controller Builder Methods

```go
func (r *MyReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        // Primary resource — events trigger Reconcile with the object's key
        For(&myv1.MyResource{}).
        // Owned resources — events map to the owner's key
        Owns(&corev1.ConfigMap{}).
        // Cross-resource watches — custom mapping function
        Watches(&corev1.Secret{},
            handler.EnqueueRequestsFromMapFunc(r.findObjectsForSecret),
        ).
        // External event source (channel-based)
        WatchesRawSource(source.Channel(eventCh, &handler.EnqueueRequestForObject{})).
        Complete(r)
}
```

### Watch with Field Index Lookups

```go
func (r *MyReconciler) findObjectsForSecret(ctx context.Context, secret client.Object) []reconcile.Request {
    // Use field index to find resources that reference this secret
    var list myv1.MyResourceList
    if err := r.client.List(ctx, &list,
        client.MatchingFields{"spec.secretRef.name": secret.GetName()},
    ); err != nil {
        return nil
    }

    requests := make([]reconcile.Request, len(list.Items))
    for i, item := range list.Items {
        requests[i] = reconcile.Request{
            NamespacedName: types.NamespacedName{
                Name:      item.GetName(),
                Namespace: item.GetNamespace(),
            },
        }
    }
    return requests
}
```

## Requeue Semantics

Understanding requeue behavior is critical for correct error handling:

| Return Value | Behavior | Use Case |
|-------------|----------|----------|
| `Result{}, err` | Exponential backoff (5ms → 1000s) | Transient errors (API server timeout, network issues) |
| `Result{Requeue: true}, nil` | Rate-limited requeue | Retry without error logging |
| `Result{RequeueAfter: d}, nil` | Requeue after exact duration, bypasses rate limiter | Scheduled work (credential rotation, polling) |
| `Result{}, nil` | Success — resets backoff counter | Reconciliation complete |

### Error Classification

Classify errors to choose the right requeue strategy:

```go
func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx) // Structured logger from context (logr)

    // ... reconciliation logic ...

    if err != nil {
        if isTransientError(err) {
            // Return error → exponential backoff
            return ctrl.Result{}, err
        }
        // Permanent error — log with structured key-value pairs and don't retry
        log.Error(err, "permanent error, not retrying",
            "resource", req.NamespacedName,
            "errorType", "permanent",
        )
        return ctrl.Result{}, nil
    }

    return ctrl.Result{}, nil
}

// Pattern from Envoy Gateway
func isTransientError(err error) bool {
    return apierrors.IsServerTimeout(err) ||
        apierrors.IsTooManyRequests(err) ||
        apierrors.IsServiceUnavailable(err) ||
        apierrors.IsTimeout(err) ||
        apierrors.IsConflict(err)
}
```

### Credential Rotation with RequeueAfter

```go
// Pattern from AI Gateway — schedule pre-rotation requeue
func (r *BSPReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ... reconcile credentials ...

    if rotator.IsExpired() {
        if err := rotator.Rotate(ctx); err != nil {
            return ctrl.Result{}, fmt.Errorf("rotating credentials: %w", err)
        }
    }

    preRotation := rotator.GetPreRotationTime()
    return ctrl.Result{RequeueAfter: time.Until(preRotation)}, nil
}
```

## Status Management

### Conditions Best Practices

```go
// Always set observedGeneration on every condition
condition := metav1.Condition{
    Type:               "Accepted",
    Status:             metav1.ConditionTrue,
    ObservedGeneration: obj.Generation,
    LastTransitionTime: metav1.Now(),
    Reason:             "Valid",
    Message:            "Resource accepted and reconciled",
}
meta.SetStatusCondition(&obj.Status.Conditions, condition)
```

Rules:
- **Positive polarity**: Use `Accepted`, `Programmed`, `Ready` — not `NotReady`, `Failed`
- **`observedGeneration`**: Set on every condition so consumers know if the status is stale
- **Transition time**: Only update when the status value actually changes
- **Reason**: PascalCase, machine-readable (e.g., `BackendNotFound`, `InvalidSpec`)
- **Message**: Human-readable explanation of the current state

### Async Status Updates

Envoy Gateway decouples status writes from the main reconcile loop using a buffered channel. **This is intentional** — EG's mega-reconciler processes 30+ types in a single pass, and blocking on individual status writes for each resource would dramatically slow the reconciliation cycle. The async pattern lets EG batch and deduplicate status updates separately from the translation pipeline.

For most controllers with per-CRD reconciliation, synchronous `retry.RetryOnConflict` is simpler and more reliable.

```go
// Buffered status update channel (Envoy Gateway pattern)
type UpdateHandler struct {
    updates chan StatusUpdate
}

func NewUpdateHandler(bufferSize int) *UpdateHandler {
    return &UpdateHandler{updates: make(chan StatusUpdate, bufferSize)}
}

// Reconciler sends status updates without blocking
func (r *MyReconciler) sendStatus(update StatusUpdate) {
    select {
    case r.updateHandler.updates <- update:
    default:
        // WARNING: Buffer full — this update is SILENTLY DROPPED.
        // The next reconcile will recompute and retry the status update.
        // Log this so operators can tune buffer size.
        log.V(1).Info("status update buffer full, will retry on next reconcile")
    }
}
```

**Caution**: The `select/default` pattern silently drops updates when the buffer is full. This is acceptable only if your reconciler is idempotent and will recompute status on the next trigger. For most controllers, synchronous status updates with `retry.RetryOnConflict` are simpler and more reliable.

### Optimistic Concurrency

Always handle conflicts when updating status:

```go
err := retry.RetryOnConflict(retry.DefaultBackoff, func() error {
    // Re-fetch the latest version
    if err := r.client.Get(ctx, key, &obj); err != nil {
        return err
    }
    // Apply status changes
    meta.SetStatusCondition(&obj.Status.Conditions, condition)
    return r.client.Status().Update(ctx, &obj)
})
if err != nil {
    return ctrl.Result{}, fmt.Errorf("updating status: %w", err)
}
```

## Ownership and Garbage Collection

### Owner References

Use owner references for Kubernetes-managed child objects. When the parent is deleted, children are garbage collected automatically.

```go
// Set owner reference — child is garbage collected when parent is deleted
if err := ctrlutil.SetControllerReference(parent, child, r.scheme); err != nil {
    return fmt.Errorf("setting controller reference: %w", err)
}
```

Rules:
- Owner and child must be in the **same namespace** (or owner is cluster-scoped)
- Only **one** controller owner per object (use `SetControllerReference`, not `SetOwnerReference`)
- Cross-namespace ownership requires finalizers instead

### Finalizers

Use finalizers **only** for cleanup of external resources (not K8s objects — those use owner references).

```go
// Generic finalizer handler pattern
// Uses MergeFrom Patch (not Update) to avoid conflicts with concurrent spec changes.
func handleFinalizer[T client.Object](
    ctx context.Context, c client.Client, obj T, finalizer string,
    cleanup func(context.Context, T) error,
) (ctrl.Result, error) {
    if obj.GetDeletionTimestamp().IsZero() {
        // Not being deleted — ensure finalizer is present
        if !ctrlutil.ContainsFinalizer(obj, finalizer) {
            patch := client.MergeFrom(obj.DeepCopyObject().(T))
            ctrlutil.AddFinalizer(obj, finalizer)
            if err := c.Patch(ctx, obj, patch); err != nil {
                return ctrl.Result{}, fmt.Errorf("adding finalizer: %w", err)
            }
        }
        return ctrl.Result{}, nil
    }

    // Being deleted — run cleanup (must be idempotent)
    if ctrlutil.ContainsFinalizer(obj, finalizer) {
        if err := cleanup(ctx, obj); err != nil {
            return ctrl.Result{}, fmt.Errorf("cleanup: %w", err)
        }
        patch := client.MergeFrom(obj.DeepCopyObject().(T))
        ctrlutil.RemoveFinalizer(obj, finalizer)
        if err := c.Patch(ctx, obj, patch); err != nil {
            return ctrl.Result{}, fmt.Errorf("removing finalizer: %w", err)
        }
    }
    return ctrl.Result{}, nil
}
```

## Structured Logging

Use `logr` (the controller-runtime logging interface) with structured key-value pairs. This is **non-negotiable** for production controllers.

```go
func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx) // Gets logger with controller name and request key pre-set

    log.Info("reconciling resource")
    log.V(1).Info("detailed operation", "phase", "translation", "backends", len(backends))
    log.Error(err, "failed to update status", "resource", req.NamespacedName)

    return ctrl.Result{}, nil
}
```

Rules:
- **Always use `log.FromContext(ctx)`** — it carries the controller name, namespace, and name
- **Structured key-value pairs** — never use `fmt.Sprintf` in log messages
- **Use log levels**: `V(0)` (default) for important events, `V(1)` for debugging
- **Never log Secret data** — even at debug level

## Event Recording

Record Kubernetes Events for user-visible state changes. Events appear in `kubectl describe` and help operators understand what the controller is doing.

```go
// Add EventRecorder to your reconciler
type MyReconciler struct {
    client   client.Client
    recorder record.EventRecorder
}

func NewMyReconciler(mgr ctrl.Manager) *MyReconciler {
    return &MyReconciler{
        client:   mgr.GetClient(),
        recorder: mgr.GetEventRecorderFor("my-controller"),
    }
}

// Record events during reconciliation
func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ... fetch obj ...

    // Normal event — informational
    r.recorder.Event(&obj, corev1.EventTypeNormal, "Reconciled", "Successfully reconciled resource")

    // Warning event — requires attention
    r.recorder.Eventf(&obj, corev1.EventTypeWarning, "BackendNotFound",
        "Backend %q not found in namespace %q", backendName, namespace)

    return ctrl.Result{}, nil
}
```

Rules:
- **Normal events** for successful operations and state transitions
- **Warning events** for recoverable errors and degraded states
- **Reason** should be PascalCase and machine-readable
- **Message** should be human-readable with enough context to diagnose

## Anti-Patterns

| Anti-Pattern | Problem | Do This Instead |
|-------------|---------|----------------|
| Edge-triggered logic | Breaks on missed/duplicate events | Derive state from current world |
| Mega-reconciler without IR/xDS justification | Scalability bottleneck, blast radius | Per-CRD controllers (see EG's rationale if your use case requires atomic translation) |
| `time.Sleep` in reconciler | Blocks the worker goroutine | Return `Result{RequeueAfter: d}` |
| Ignoring `client.IgnoreNotFound` | Logs error for normal deletions | `client.IgnoreNotFound(err)` on Get |
| Status update without retry | Fails on concurrent updates | `retry.RetryOnConflict` |
| Bare error returns | No context for debugging | `fmt.Errorf("context: %w", err)` |
| `client.Update` for finalizers | Conflicts with concurrent spec changes | `client.Patch` with `MergeFrom` |
| Finalizer without cleanup | Object stuck in terminating state | Always remove finalizer after cleanup |
| Owner ref across namespaces | Silently fails | Use finalizers for cross-namespace |
| Not setting `observedGeneration` | Consumers can't detect stale status | Always set on every condition |
| Reconciling deleted objects | Wasted work, potential errors | Check `DeletionTimestamp` early |
| Unstructured `log.Error(err, msg)` | Can't filter or aggregate | `log.FromContext(ctx)` with key-value pairs |
| `fmt.Sprintf` in log messages | Not machine-parseable | Structured key-value pairs: `log.Info("msg", "key", val)` |
| No Event recording | Operators can't see controller actions | `EventRecorder` for user-visible state changes |
| Logging every reconcile at V(0) | Noise at scale | `V(1)` for routine operations, `V(0)` for significant changes |
