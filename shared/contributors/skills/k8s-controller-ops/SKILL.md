---
name: k8s-controller-ops
description: Operational patterns for Kubernetes controllers — leader election, RBAC, finalizer safety, Server-Side Apply, extension hooks, credential rotation, and drift detection
---

# Controller Operations

Operational patterns for running Kubernetes controllers in production. Covers leader election, RBAC management, finalizer safety, Server-Side Apply, extension points, credential rotation, and drift detection.

## Leader Election

### Lease-Based Election

Use Lease objects (not ConfigMaps) for leader election:

```go
mgr, err := ctrl.NewManager(cfg, ctrl.Options{
    LeaderElection:          true,
    LeaderElectionID:        "my-controller-leader",
    LeaderElectionNamespace: "my-system",
    // Graceful shutdown: release lease when stopping
    LeaderElectionReleaseOnCancel: true,
})
```

### Leader Election Best Practice

The default and recommended behavior is to run controllers **only on the leader replica**. This is what controller-runtime does by default when `LeaderElection: true` is set.

```go
// DEFAULT (recommended): Controllers only run on leader
mgr, err := ctrl.NewManager(cfg, ctrl.Options{
    LeaderElection:                true,
    LeaderElectionID:              "my-controller-leader",
    LeaderElectionReleaseOnCancel: true,
})
// Controllers automatically only run on the elected leader
```

### NeedLeaderElection: false — Reserved for Specific Use Cases

Setting `NeedLeaderElection: ptr.To(false)` on controllers causes them to run on ALL replicas simultaneously, which for most controllers leads to:
- **Duplicate reconciliations** across replicas
- **Race conditions** on status updates
- **Increased API server load** from multiple writers

For most new controllers, use the default (leader-only) behavior.

```go
// Webhooks — must be available on all replicas to serve admission requests
mgr.GetWebhookServer().NeedLeaderElection = ptr.To(false)
```

#### Envoy Gateway's Leader-Gated Status Pattern

Envoy Gateway intentionally uses `NeedLeaderElection: false` on its controllers. This is **not an oversight** — it's a deliberate design decision for operational resilience:

```go
// EG pattern: controllers on all replicas, status updates gated to leader
ctrl.NewControllerManagedBy(mgr).
    WithOptions(controller.Options{
        NeedLeaderElection: ptr.To(false), // Run on all replicas
    }).
    Complete(r)
```

**Why EG does this**:
- **Fast failover**: Controllers are already warm on standby replicas — when leadership transfers, the new leader doesn't need to cold-start its cache or re-list all resources
- **No split-brain for writes**: Only the leader writes status updates (gated via an `elected` channel), so there's no conflict between replicas
- **Reduced failover blast radius**: The mega-reconciler's IR/xDS translation is expensive; cold-starting it on failover would cause visible latency to proxies

**Trade-off**: This increases API server read load (all replicas watch all resources) in exchange for sub-second failover. This is worthwhile for EG because the alternative — a 15-30s leader election timeout plus full cache warm-up — means Envoy proxies receive stale xDS during that window.

**Guidance**: For new controllers, start with leader-only (the default). Only adopt EG's pattern if you have measured that leader election failover time is unacceptable for your use case and you can guarantee write operations are leader-gated.

### Leader Election Configuration

| Parameter | Default | Recommendation |
|-----------|---------|---------------|
| LeaseDuration | 15s | Keep default unless you need faster failover |
| RenewDeadline | 10s | Must be < LeaseDuration |
| RetryPeriod | 2s | Must be < RenewDeadline |
| ReleaseOnCancel | false | Set `true` for graceful shutdown |

## RBAC Management

### controller-gen RBAC Markers (Recommended)

Use `controller-gen` RBAC markers as the **source of truth** for RBAC definitions. This is the standard approach recommended by Kubebuilder and Operator SDK, ensuring RBAC stays in sync with the code.

```go
// +kubebuilder:rbac:groups=my.example.com,resources=myresources,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=my.example.com,resources=myresources/status,verbs=update;patch
// +kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=services;endpoints,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch
// +kubebuilder:rbac:groups=coordination.k8s.io,resources=leases,verbs=get;list;watch;create;update;patch;delete

func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ...
}
```

Then generate RBAC manifests:

```bash
controller-gen rbac:roleName=my-controller paths="./..." output:rbac:dir=config/rbac
```

#### Why EG and AIGW Use Manual Helm RBAC Instead

Envoy Gateway and AI Gateway maintain RBAC manually in Helm chart templates rather than using controller-gen markers. This is a deliberate choice:

- **Helm templating**: RBAC rules need conditional logic (`{{- if .Values.featureX.enabled }}`) that controller-gen markers can't express
- **Single chart artifact**: The Helm chart is the sole deployment artifact — having RBAC defined there avoids a second source of truth
- **Cross-component RBAC**: The chart defines RBAC for multiple components (controller, certgen, ratelimit) that don't share a Go module

For new projects without Helm-driven deployment complexity, prefer controller-gen markers to keep RBAC synchronized with code.

### Minimum Privilege Principle

| Resource | Verbs Needed | Notes |
|----------|:------------:|-------|
| Your CRDs | get, list, watch, update, patch | update for finalizers, patch for status |
| Your CRDs/status | update, patch | Separate permission for status subresource |
| Secrets (if referenced) | get, list, watch | **Never** update, create, or delete Secrets |
| ConfigMaps (owned) | get, list, watch, create, update, delete | Only if controller creates ConfigMaps |
| Leases | get, list, watch, create, update, patch, delete | Leader election |
| Events | create, patch | For recording events |

### Cluster vs. Namespace Scope

```yaml
# ClusterRole — for cluster-scoped CRDs or cross-namespace operations
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
# ...

# Role — for namespace-scoped operations only
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: my-system
# ...
```

## Finalizer Safety

### The Finalizer Contract

1. **Add finalizer** when the object is first reconciled (before creating external resources)
2. **On deletion**: detect via `DeletionTimestamp`, run cleanup, then remove finalizer
3. **Cleanup must be idempotent** — it may run multiple times if the controller restarts
4. **Remove finalizer LAST** — only after all cleanup is confirmed complete

### Generic Finalizer Pattern

Always use `MergeFrom` Patch (not Update) for finalizer operations to avoid conflicts with concurrent spec changes:

```go
const finalizerName = "myresource.example.com/cleanup"

func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var obj myv1.MyResource
    if err := r.client.Get(ctx, req.NamespacedName, &obj); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // Handle deletion
    if !obj.DeletionTimestamp.IsZero() {
        if ctrlutil.ContainsFinalizer(&obj, finalizerName) {
            // Run cleanup (must be idempotent)
            if err := r.cleanupExternalResources(ctx, &obj); err != nil {
                return ctrl.Result{}, fmt.Errorf("cleanup: %w", err)
            }

            // Remove finalizer AFTER cleanup succeeds — use Patch, not Update
            patch := client.MergeFrom(obj.DeepCopy())
            ctrlutil.RemoveFinalizer(&obj, finalizerName)
            if err := r.client.Patch(ctx, &obj, patch); err != nil {
                return ctrl.Result{}, fmt.Errorf("removing finalizer: %w", err)
            }
        }
        return ctrl.Result{}, nil
    }

    // Ensure finalizer is present — use Patch, not Update
    if !ctrlutil.ContainsFinalizer(&obj, finalizerName) {
        patch := client.MergeFrom(obj.DeepCopy())
        ctrlutil.AddFinalizer(&obj, finalizerName)
        if err := r.client.Patch(ctx, &obj, patch); err != nil {
            return ctrl.Result{}, fmt.Errorf("adding finalizer: %w", err)
        }
    }

    // ... normal reconciliation ...
    return ctrl.Result{}, nil
}
```

**Why Patch over Update**: `client.Update` replaces the entire object, causing conflicts if the spec was modified concurrently. `MergeFrom` Patch only modifies the finalizer field, avoiding conflicts with other writers.

### When to Use Finalizers vs. Owner References

| Mechanism | Use When | Example |
|-----------|----------|---------|
| Owner references | Child is a K8s object in the same namespace | ConfigMap created by controller |
| Finalizers | External resource (not K8s) needs cleanup | Cloud load balancer, DNS record |
| Finalizers | Cross-namespace cleanup needed | Resources in different namespaces |
| Neither | No cleanup needed | Pure status-computing controllers |

## Server-Side Apply (SSA)

### When to Use SSA

SSA is recommended for managing owned resources. It provides:
- Conflict detection between controllers
- Field-level ownership tracking
- Declarative intent (apply desired state, not mutations)

```go
// Apply an owned ConfigMap using SSA
cm := &corev1.ConfigMap{
    TypeMeta: metav1.TypeMeta{
        APIVersion: "v1",
        Kind:       "ConfigMap",
    },
    ObjectMeta: metav1.ObjectMeta{
        Name:      "my-config",
        Namespace: "default",
    },
    Data: map[string]string{
        "config.yaml": configData,
    },
}

// ForceOwnership: true allows the controller to take over fields owned by other managers.
// This is required when adopting resources that were previously managed by other tools (e.g., kubectl).
err := r.client.Patch(ctx, cm, client.Apply,
    client.FieldOwner("my-controller"),
    client.ForceOwnership,
)
```

**Important**: Always set `TypeMeta` (APIVersion + Kind) on objects used with SSA — the API server requires it to identify the resource type.

### SSA vs. MergeFrom Patch

| Approach | Use When | Pros | Cons |
|----------|----------|------|------|
| SSA (`client.Apply`) | Managing entire objects | Conflict detection, field ownership | Requires TypeMeta, learning curve |
| MergeFrom patch | Updating specific fields | Simple, familiar | No field ownership tracking |
| Update | Full object replacement | Simple | Lost updates risk, requires re-fetch |

Envoy Gateway uses `MergeFrom` for finalizer patches (targeted field update). SSA is better for managing complete owned resources.

## Extension and Hook Patterns

### gRPC Extension Server (AI Gateway)

AI Gateway supports external extension servers that hook into the processing pipeline:

```go
// Extension server interface
type ExtensionServer interface {
    // PostRouteModify is called after route selection
    PostRouteModify(ctx context.Context, req *PostRouteModifyRequest) (*PostRouteModifyResponse, error)

    // PostTranslateModify is called after request translation
    PostTranslateModify(ctx context.Context, req *PostTranslateModifyRequest) (*PostTranslateModifyResponse, error)
}
```

### Plugin Architecture Considerations

When designing extension points for your controller:

1. **Define clear hook points** in the processing pipeline
2. **Use interfaces** — allow external implementations via gRPC or in-process plugins
3. **Provide default no-op implementations** for optional hooks
4. **Document the contract** — what data is available, what can be modified, ordering guarantees
5. **Handle failures gracefully** — extension failures should not crash the controller

## Credential Rotation

### Rotator Pattern (AI Gateway)

```go
// Rotator interface for credential lifecycle management
type Rotator interface {
    // IsExpired returns true if the credential has expired
    IsExpired() bool

    // GetPreRotationTime returns when rotation should start
    // (before actual expiry, to allow for rotation latency)
    GetPreRotationTime() time.Time

    // Rotate performs the credential rotation
    Rotate(ctx context.Context) error
}

// In reconciler — schedule pre-rotation requeue
func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ... fetch and validate credential ...

    rotator := r.getRotator(credential)

    if rotator.IsExpired() {
        if err := rotator.Rotate(ctx); err != nil {
            return ctrl.Result{}, fmt.Errorf("rotating credential: %w", err)
        }
    }

    // Schedule requeue before expiry
    preRotation := rotator.GetPreRotationTime()
    if time.Until(preRotation) > 0 {
        return ctrl.Result{RequeueAfter: time.Until(preRotation)}, nil
    }

    return ctrl.Result{}, nil
}
```

### Secure Secret Handling

- **Never log** Secret data (even at debug level)
- **Never store** credentials in status fields
- **Minimize** the time credentials are held in memory
- **Watch Secrets** for external rotation (not just controller-initiated)
- Remember: Secrets don't update `.metadata.generation` — use content-based change detection

## Drift Detection

### Periodic Re-Sync

controller-runtime supports periodic re-sync to detect drift from desired state:

```go
mgr, err := ctrl.NewManager(cfg, ctrl.Options{
    Cache: cache.Options{
        SyncPeriod: ptr.To(10 * time.Minute), // Re-list all resources periodically
    },
})
```

This triggers reconciliation for all watched objects at the configured interval, catching:
- Manual modifications to owned resources
- External system state changes
- Missed events during transient connectivity issues

### External State Polling

For resources that represent external state (cloud resources, DNS records):

```go
import "k8s.io/apimachinery/pkg/api/equality"

func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ... fetch K8s object ...

    // Check external state
    externalState, err := r.externalClient.GetState(ctx, obj.Spec.ExternalID)
    if err != nil {
        return ctrl.Result{}, fmt.Errorf("checking external state: %w", err)
    }

    // Compare and reconcile drift
    // Use equality.Semantic.DeepEqual — NOT reflect.DeepEqual.
    // It handles resource.Quantity, metav1.Time, and other K8s types correctly.
    if !equality.Semantic.DeepEqual(obj.Spec.DesiredConfig, externalState.Config) {
        if err := r.externalClient.UpdateState(ctx, obj.Spec.ExternalID, obj.Spec.DesiredConfig); err != nil {
            return ctrl.Result{}, fmt.Errorf("correcting drift: %w", err)
        }
    }

    // Poll again after interval
    return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
}
```

**Never use `reflect.DeepEqual`** to compare Kubernetes objects. It fails for types like `resource.Quantity` (which can represent the same value in different formats) and `metav1.Time`. Always use `equality.Semantic.DeepEqual` from `k8s.io/apimachinery/pkg/api/equality`.

## Checklist for Production Controllers

- [ ] Leader election configured with `ReleaseOnCancel: true`
- [ ] Controllers run only on leader (default) — `NeedLeaderElection: false` only for webhooks
- [ ] RBAC defined with controller-gen markers (or documented reason for manual Helm RBAC)
- [ ] RBAC follows minimum privilege principle
- [ ] Finalizers use `MergeFrom` Patch (not Update) and are idempotent
- [ ] Status updates use `retry.RetryOnConflict`
- [ ] Secrets are never logged or stored in status
- [ ] Credential rotation is scheduled before expiry
- [ ] Structured logging with `log.FromContext(ctx)` and key-value pairs
- [ ] Event recording with `EventRecorder` for user-visible state changes
- [ ] Object comparison uses `equality.Semantic.DeepEqual` (not `reflect.DeepEqual`)
- [ ] SSA with `ForceOwnership` for managing owned resources
- [ ] Cache optimized (strip managed fields, label selectors if applicable)
- [ ] Metrics exported for reconciliation count, duration, errors, queue depth
- [ ] Graceful shutdown handles in-flight reconciliations
- [ ] Drift detection via periodic re-sync or external polling
- [ ] Health check endpoints (/healthz, /readyz) configured
