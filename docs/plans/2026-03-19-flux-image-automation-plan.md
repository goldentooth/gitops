# Flux Image Auto-Deploy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically deploy new MCP server Docker images when CI builds complete, using Flux image automation with timestamp-prefixed SHA tags.

**Architecture:** Flux's image-reflector-controller scans the private registry for new tags. An ImagePolicy selects the newest tag by timestamp. ImageUpdateAutomation commits the updated tag back to gitops, triggering a normal Flux reconciliation that deploys the new image.

**Tech Stack:** Flux Image Automation (ImageRepository, ImagePolicy, ImageUpdateAutomation), Kustomize, Forgejo Actions (CI workflow update)

---

### Task 1: Move MCP Deployment Manifests into gitops

**Files:**
- Create: `apps/mcp/namespace.yaml`
- Create: `apps/mcp/deployment.yaml`
- Create: `apps/mcp/service.yaml`
- Create: `apps/mcp/kustomization.yaml`
- Modify: `apps/kustomization.yaml`

**Step 1: Create the app directory and manifests**

Create `apps/mcp/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: goldentooth-mcp
```

Create `apps/mcp/deployment.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: goldentooth-mcp
  namespace: goldentooth-mcp
  labels:
    app: goldentooth-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: goldentooth-mcp
  template:
    metadata:
      labels:
        app: goldentooth-mcp
    spec:
      containers:
        - name: goldentooth-mcp
          image: registry.goldentooth.net/goldentooth-mcp:latest # {"$imagepolicy": "flux-system:mcp"}
          ports:
            - name: dev
              containerPort: 8080
              protocol: TCP
            - name: auth
              containerPort: 8443
              protocol: TCP
          env:
            - name: GOLDENTOOTH_MCP_DEV
              value: "true"
            - name: RUST_LOG
              value: "info"
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

Note the `# {"$imagepolicy": "flux-system:mcp"}` marker comment on the image line. This is how ImageUpdateAutomation knows where to write updated tags.

Create `apps/mcp/service.yaml`:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: goldentooth-mcp
  namespace: goldentooth-mcp
  labels:
    app: goldentooth-mcp
spec:
  selector:
    app: goldentooth-mcp
  ports:
    - name: dev
      port: 8080
      targetPort: 8080
      protocol: TCP
    - name: auth
      port: 8443
      targetPort: 8443
      protocol: TCP
```

Create `apps/mcp/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
```

**Step 2: Register in apps kustomization**

Add `- mcp` to `apps/kustomization.yaml` resources list (note: apps uses a mix of `.yaml` files and directories — this follows the directory pattern).

**Step 3: Commit**

```bash
git add apps/mcp/ apps/kustomization.yaml
git commit -m "feat(mcp): move deployment manifests into gitops"
```

---

### Task 2: Update CI Workflow for Timestamp Tags

**Files:**
- Modify: `/Users/nathan/Projects/goldentooth/mcp/.forgejo/workflows/ci.yaml`

**Step 1: Update the workflow**

Replace the current CI workflow with timestamp-prefixed tags:

```yaml
name: CI Build

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and push Docker image
        uses: docker://gcr.io/kaniko-project/executor:latest
        env:
          BUILD_TAG: ${{ github.run_number }}-${{ github.sha }}
        with:
          args: >-
            --dockerfile=Dockerfile
            --context=.
            --destination=registry.goldentooth.net/goldentooth-mcp:${{ github.run_number }}-${{ github.sha }}
            --destination=registry.goldentooth.net/goldentooth-mcp:latest
            --skip-tls-verify
```

Note: We use `github.run_number` (monotonically increasing integer) instead of `$(date +%s)` because shell commands aren't available inside Forgejo Actions `args`. `run_number` is numerically sortable and always increases, which is what the ImagePolicy needs.

**Step 2: Commit and push to GitHub**

```bash
cd /Users/nathan/Projects/goldentooth/mcp
git add .forgejo/workflows/ci.yaml
git commit -m "ci: use run-number prefixed tags for Flux image automation"
git push
```

---

### Task 3: Create ImageRepository and ImagePolicy

**Files:**
- Create: `apps/mcp/image-repository.yaml`
- Create: `apps/mcp/image-policy.yaml`
- Modify: `apps/mcp/kustomization.yaml`

**Step 1: Create ImageRepository**

Create `apps/mcp/image-repository.yaml`:

```yaml
---
# Scans the private registry for new goldentooth-mcp image tags.
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: mcp
  namespace: flux-system
spec:
  image: registry.goldentooth.net/goldentooth-mcp
  interval: 1m
  insecure: true
```

Note: `insecure: true` skips TLS verification. The registry uses Step-CA with short-lived certs, and configuring the CA chain for the image-reflector-controller is more complexity than it's worth for an internal-only registry. If this doesn't work (some Flux versions require `provider: generic`), try adding `secretRef` with the registry CA cert instead.

**Step 2: Create ImagePolicy**

Create `apps/mcp/image-policy.yaml`:

```yaml
---
# Selects the newest image by run_number prefix (numerically sortable).
# Tags follow format: <run_number>-<sha> (e.g., "5-d53a7b81...")
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: mcp
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: mcp
  policy:
    numerical:
      order: asc
  filterTags:
    pattern: '^(?P<num>[0-9]+)-[a-f0-9]+$'
    extract: '$num'
```

The `filterTags` pattern matches `<number>-<hex>` tags, extracts the numeric prefix, and `numerical.order: asc` selects the highest number (newest build).

**Step 3: Update kustomization**

Add `image-repository.yaml` and `image-policy.yaml` to `apps/mcp/kustomization.yaml` resources.

**Step 4: Commit**

```bash
git add apps/mcp/
git commit -m "feat(mcp): add ImageRepository and ImagePolicy for auto-deploy"
```

---

### Task 4: Create ImageUpdateAutomation

**Files:**
- Create: `apps/mcp/image-update-automation.yaml`
- Modify: `apps/mcp/kustomization.yaml`

**Step 1: Create ImageUpdateAutomation**

Create `apps/mcp/image-update-automation.yaml`:

```yaml
---
# Commits updated image tags back to the gitops repo.
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: mcp
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: fluxcdbot
        email: flux@goldentooth.net
      messageTemplate: 'chore(flux): update mcp image to {{range .Changed.Changes}}{{print .NewValue}}{{end}}'
    push:
      branch: main
  update:
    path: ./apps/mcp
    strategy: Setters
```

The `update.path` restricts image updates to the `apps/mcp/` directory. The `Setters` strategy uses the `$imagepolicy` marker comments in deployment.yaml to know where to write.

**Step 2: Update kustomization**

Add `image-update-automation.yaml` to `apps/mcp/kustomization.yaml` resources.

**Step 3: Commit**

```bash
git add apps/mcp/
git commit -m "feat(mcp): add ImageUpdateAutomation for gitops commits"
```

---

### Task 5: Push, Reconcile, and Verify

**Step 1: Push gitops changes**

```bash
cd /Users/nathan/Projects/goldentooth/gitops
git push
```

**Step 2: Reconcile Flux**

```bash
flux reconcile kustomization apps --with-source
```

Wait for reconciliation to complete.

**Step 3: Verify resources exist**

```bash
kubectl get imagerepository -n flux-system mcp
kubectl get imagepolicy -n flux-system mcp
kubectl get imageupdateautomation -n flux-system mcp
kubectl get pods -n goldentooth-mcp
```

Expected: all resources present, MCP pod running.

**Step 4: Check ImageRepository is scanning**

```bash
kubectl get imagerepository -n flux-system mcp -o yaml
```

Look for `status.lastScanResult` showing discovered tags. If there's an error (e.g., TLS), troubleshoot the registry connection.

**Step 5: Check ImagePolicy selected a tag**

```bash
kubectl get imagepolicy -n flux-system mcp -o yaml
```

Look for `status.latestImage` showing the selected tag.

---

### Task 6: Trigger a Build and Verify End-to-End

**Step 1: Wait for mirror sync + CI build**

The commit from Task 2 (CI workflow update) should have been mirrored to Forgejo and triggered a build. If not yet, force a mirror sync:

```bash
curl -ks -X POST https://git.goldentooth.net/api/v1/repos/forgejo_admin/mcp/mirror-sync \
  -u "forgejo_admin:<password>"
```

Wait for the Actions run to complete (check Forgejo UI or API).

**Step 2: Verify new tag in registry**

```bash
curl -ks https://registry.goldentooth.net/v2/goldentooth-mcp/tags/list
```

Expected: a tag matching `<run_number>-<sha>` pattern alongside `latest`.

**Step 3: Verify Flux picked up the new tag**

```bash
kubectl get imagepolicy -n flux-system mcp -o jsonpath='{.status.latestImage}'
```

Expected: the new `<run_number>-<sha>` tag.

**Step 4: Verify Flux committed the tag update**

```bash
git pull
git log --oneline -3
```

Expected: a commit from `fluxcdbot` updating the image tag in `apps/mcp/deployment.yaml`.

**Step 5: Verify the MCP pod is running the new image**

```bash
kubectl get pods -n goldentooth-mcp -o jsonpath='{.items[0].spec.containers[0].image}'
```

Expected: `registry.goldentooth.net/goldentooth-mcp:<run_number>-<sha>`.
