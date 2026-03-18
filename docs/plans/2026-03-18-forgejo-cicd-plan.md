# Forgejo + CI/CD Pipeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Forgejo as a GitHub mirror with Forgejo Actions CI to build the MCP server Docker image on-cluster.

**Architecture:** Forgejo mirrors repos from GitHub and triggers Actions workflows on push. A Forgejo Runner pod on MNOP executes builds using Kaniko to produce ARM64 Docker images, pushing them to the private registry. Flux deploys the updated images.

**Tech Stack:** Forgejo (Helm, OCI), Forgejo Runner (raw manifests), Kaniko (container image builds), Flux CD (GitOps), SOPS/Age (secrets), Gateway API (ingress)

---

### Task 1: Create Forgejo Namespace and SOPS Secret

**Files:**
- Create: `infrastructure/forgejo/namespace.yaml`
- Create: `infrastructure/forgejo/admin-secret.yaml`
- Create: `infrastructure/forgejo/kustomization.yaml`

**Step 1: Create the namespace**

Create `infrastructure/forgejo/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: forgejo
```

**Step 2: Create the admin secret (plaintext first, then encrypt)**

Create `infrastructure/forgejo/admin-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: forgejo-admin
  namespace: forgejo
type: Opaque
stringData:
  username: forgejo_admin
  password: <generate-a-random-password>
```

Encrypt with SOPS:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --encrypt \
  --age age179hfp3n7e42d2fazj09tvjjxpav6ztr3z98g0hwaxpunyfd7rcnqcv0x27 \
  --encrypted-regex '^(data|stringData)$' \
  --in-place infrastructure/forgejo/admin-secret.yaml
```

**Step 3: Create the kustomization**

Create `infrastructure/forgejo/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - admin-secret.yaml
```

**Step 4: Commit**

```bash
git add infrastructure/forgejo/
git commit -m "feat(forgejo): add namespace and admin secret"
```

---

### Task 2: Create Forgejo HelmRepository and HelmRelease

**Files:**
- Create: `infrastructure/forgejo/repository.yaml`
- Create: `infrastructure/forgejo/release.yaml`
- Modify: `infrastructure/forgejo/kustomization.yaml`

**Step 1: Create OCI HelmRepository**

Create `infrastructure/forgejo/repository.yaml`:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: forgejo
  namespace: flux-system
spec:
  interval: 24h
  type: oci
  url: oci://code.forgejo.org/forgejo-helm
```

**Step 2: Create HelmRelease**

Create `infrastructure/forgejo/release.yaml`:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: forgejo
  namespace: flux-system
spec:
  interval: 30m
  targetNamespace: forgejo
  chart:
    spec:
      chart: forgejo
      version: ">=16.0.0 <17.0.0"
      sourceRef:
        kind: HelmRepository
        name: forgejo
        namespace: flux-system
      interval: 12h
  install:
    createNamespace: false
    remediation:
      retries: 3
    timeout: 10m
  upgrade:
    remediation:
      retries: 3
    timeout: 10m
  values:
    image:
      rootless: true

    gitea:
      admin:
        existingSecret: forgejo-admin
      config:
        actions:
          ENABLED: true
        mirror:
          ENABLED: true
          MIN_INTERVAL: 5m
        server:
          DOMAIN: git.goldentooth.net
          ROOT_URL: https://git.goldentooth.net/
        service:
          DISABLE_REGISTRATION: true
        database:
          DB_TYPE: sqlite3

    persistence:
      enabled: true
      storageClass: seaweedfs
      size: 10Gi

    nodeSelector:
      node.kubernetes.io/disk-type: nvme

    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: "1"
        memory: 512Mi
```

**Step 3: Update kustomization**

Add `repository.yaml` and `release.yaml` to `infrastructure/forgejo/kustomization.yaml` resources.

**Step 4: Commit**

```bash
git add infrastructure/forgejo/
git commit -m "feat(forgejo): add HelmRepository and HelmRelease"
```

---

### Task 3: Add Gateway Route and TLS Certificate

**Files:**
- Create: `infrastructure/gateway/routes/forgejo.yaml`
- Modify: `infrastructure/gateway/routes/kustomization.yaml`
- Modify: `infrastructure/gateway/certificate.yaml`

**Step 1: Create HTTPRoute**

Create `infrastructure/gateway/routes/forgejo.yaml`:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: forgejo
  namespace: forgejo
spec:
  parentRefs:
    - name: goldentooth
      namespace: gateway
      sectionName: https
  hostnames:
    - git.goldentooth.net
  rules:
    - backendRefs:
        - name: forgejo-http
          port: 3000
```

**Step 2: Add to routes kustomization**

Add `- forgejo.yaml` to `infrastructure/gateway/routes/kustomization.yaml` resources.

**Step 3: Add DNS name to TLS certificate**

Add `- git.goldentooth.net` to the `dnsNames` list in `infrastructure/gateway/certificate.yaml`.

**Step 4: Commit**

```bash
git add infrastructure/gateway/
git commit -m "feat(forgejo): add gateway route and TLS certificate"
```

---

### Task 4: Register Forgejo in Infrastructure Kustomization

**Files:**
- Modify: `infrastructure/kustomization.yaml`

**Step 1: Add forgejo to infrastructure resources**

Add `- forgejo` to the resources list in `infrastructure/kustomization.yaml`.

**Step 2: Commit and push**

```bash
git add infrastructure/kustomization.yaml
git commit -m "feat(forgejo): register in infrastructure kustomization"
git push
```

**Step 3: Wait for Flux to reconcile**

```bash
flux reconcile kustomization infrastructure --with-source
kubectl get pods -n forgejo -w
```

Wait until the Forgejo pod is Running.

**Step 4: Verify Forgejo is accessible**

```bash
curl -kI https://git.goldentooth.net/
```

Expected: HTTP 200 with Forgejo page.

---

### Task 5: Create GitHub Mirror Repository

**Step 1: Get Forgejo admin password**

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt \
  infrastructure/forgejo/admin-secret.yaml | grep password
```

**Step 2: Create mirror via Forgejo API**

```bash
curl -k -X POST https://git.goldentooth.net/api/v1/repos/migrate \
  -H "Content-Type: application/json" \
  -u "forgejo_admin:<password>" \
  -d '{
    "clone_addr": "https://github.com/goldentooth/mcp.git",
    "repo_name": "mcp",
    "repo_owner": "forgejo_admin",
    "service": "github",
    "mirror": true,
    "mirror_interval": "5m"
  }'
```

Expected: 201 Created with repo JSON.

**Step 3: Verify mirror synced**

```bash
curl -k https://git.goldentooth.net/api/v1/repos/forgejo_admin/mcp \
  -u "forgejo_admin:<password>" | jq '.mirror, .updated_at'
```

Expected: `mirror: true` with recent timestamp.

**Step 4: Commit** (no files to commit, API-only step)

---

### Task 6: Deploy Forgejo Runner

**Files:**
- Create: `infrastructure/forgejo/runner-secret.yaml`
- Create: `infrastructure/forgejo/runner-deployment.yaml`
- Modify: `infrastructure/forgejo/kustomization.yaml`

**Step 1: Generate runner shared secret**

```bash
openssl rand -hex 20
```

Save output — this is the shared secret for offline runner registration.

**Step 2: Register runner in Forgejo**

```bash
kubectl exec -n forgejo deploy/forgejo -- \
  forgejo forgejo-cli actions register --secret <hex-secret>
```

**Step 3: Create runner secret**

Create `infrastructure/forgejo/runner-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: forgejo-runner
  namespace: forgejo
type: Opaque
stringData:
  token: <hex-secret>
```

Encrypt with SOPS:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --encrypt \
  --age age179hfp3n7e42d2fazj09tvjjxpav6ztr3z98g0hwaxpunyfd7rcnqcv0x27 \
  --encrypted-regex '^(data|stringData)$' \
  --in-place infrastructure/forgejo/runner-secret.yaml
```

**Step 4: Create runner deployment**

Create `infrastructure/forgejo/runner-deployment.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: forgejo-runner
  namespace: forgejo
  labels:
    app: forgejo-runner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: forgejo-runner
  template:
    metadata:
      labels:
        app: forgejo-runner
    spec:
      nodeSelector:
        node.kubernetes.io/disk-type: nvme
      containers:
        - name: runner
          image: code.forgejo.org/forgejo/runner:6.3.1
          env:
            - name: FORGEJO_RUNNER_INSTANCE
              value: https://forgejo-http.forgejo.svc.cluster.local:3000
            - name: FORGEJO_RUNNER_SECRET
              valueFrom:
                secretKeyRef:
                  name: forgejo-runner
                  key: token
            - name: FORGEJO_RUNNER_NAME
              value: bramble-runner
            - name: FORGEJO_RUNNER_LABELS
              value: "ubuntu-latest:docker://node:20-bookworm"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "2"
              memory: 1Gi
```

Note: The runner deployment details (especially env vars and registration mechanism) may need adjustment based on the actual runner image's entrypoint. Verify the runner image docs during implementation.

**Step 5: Update kustomization**

Add `runner-secret.yaml` and `runner-deployment.yaml` to `infrastructure/forgejo/kustomization.yaml` resources.

**Step 6: Commit**

```bash
git add infrastructure/forgejo/
git commit -m "feat(forgejo): add Actions runner deployment"
```

---

### Task 7: Create CI Workflow for MCP Server

**Files:**
- Create: `<mcp-repo>/.forgejo/workflows/ci.yaml`

**Step 1: Create the workflow**

Create `.forgejo/workflows/ci.yaml` in the MCP repo:

```yaml
name: CI

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
        with:
          args: >-
            --dockerfile=Dockerfile
            --context=.
            --destination=registry.goldentooth.net/goldentooth-mcp:${{ github.sha }}
            --destination=registry.goldentooth.net/goldentooth-mcp:latest
            --skip-tls-verify
```

Note: Kaniko in Forgejo Actions may need a different invocation pattern than GitHub Actions. The exact step syntax should be verified during implementation — Forgejo Actions supports `uses: docker://` for running arbitrary container images as steps.

**Step 2: Commit and push to GitHub**

```bash
cd /Users/nathan/Projects/goldentooth/mcp
git add .forgejo/workflows/ci.yaml
git commit -m "ci: add Forgejo Actions workflow for Docker image build"
git push
```

**Step 3: Wait for mirror sync (up to 5 minutes)**

Check Forgejo UI or API for the mirrored commit. Then check the Actions tab for the triggered workflow run.

**Step 4: Verify the built image**

```bash
curl -s https://registry.goldentooth.net/v2/goldentooth-mcp/tags/list
```

Expected: new SHA tag appears alongside `latest`.

---

### Task 8: Push All Changes and Verify End-to-End

**Step 1: Push gitops changes**

```bash
cd /Users/nathan/Projects/goldentooth/gitops
git push
```

**Step 2: Wait for full reconciliation**

```bash
flux reconcile kustomization infrastructure --with-source
kubectl get pods -n forgejo
```

Expected: `forgejo-0` and `forgejo-runner-*` pods Running.

**Step 3: End-to-end test**

Make a trivial change to the MCP repo on GitHub, push it, wait for:
1. Forgejo mirror sync (≤5 min)
2. Actions workflow trigger
3. Docker image build + push
4. Verify new image in registry

**Step 4: Commit any fixups from the verification process**
