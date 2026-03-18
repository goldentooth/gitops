# Forgejo + CI/CD Pipeline Design

## Goal

Self-hosted git forge with CI/CD on the bramble. GitHub remains the source
of truth; Forgejo mirrors repos and runs CI pipelines that build Docker
images and push them to the private registry.

## Architecture

```
GitHub (source of truth)
    │
    │ mirror sync (Forgejo pulls every 5 min)
    ▼
Forgejo (git.goldentooth.net)
    │
    │ push event triggers Forgejo Actions
    ▼
Forgejo Runner (pod on MNOP)
    │
    │ kaniko build + push
    ▼
Docker Registry (registry.goldentooth.net)
    │
    │ Flux deploys updated image
    ▼
Cluster
```

## Components

### Forgejo

- **Helm chart**: `forgejo-helm/forgejo` (official)
- **Namespace**: `forgejo`
- **Storage**: 10Gi SeaweedFS PVC (git repos + SQLite database)
- **Ingress**: `git.goldentooth.net` via Gateway API
- **Database**: embedded SQLite
- **Node selector**: `node.kubernetes.io/disk-type: nvme` (MNOP)
- **Mirror**: pull `goldentooth/mcp` from GitHub every 5 minutes
- **Auth**: single admin account

### Forgejo Runner

- **Image**: `gitea/act_runner`
- **Registration**: shared token with Forgejo instance
- **Node selector**: `node.kubernetes.io/disk-type: nvme` (MNOP)
- **Build strategy**: Kaniko (no DinD, no privileged containers)
- **Labels**: map `runs-on` values to container images

### CI Workflow

File: `.forgejo/workflows/ci.yaml` in the MCP repo.

- **Trigger**: push to `main` (fires when mirror syncs)
- **Steps**:
  1. `cargo test` — run tests
  2. Kaniko build — build ARM64 Docker image from Dockerfile
  3. Push to `registry.goldentooth.net/goldentooth-mcp:<sha>` and `:latest`
- **Registry credentials**: injected via Forgejo secret

## Storage

SeaweedFS PVCs for all persistent data. Since Forgejo is a mirror (GitHub
is source of truth), data loss only means re-mirroring — no git data is
at risk.

## Explicit Non-Goals

- No Flux Image Automation (manual tag bumps or `:latest` for now)
- No GitHub webhooks (Forgejo pulls on schedule)
- No multi-user auth (single admin)
- No PostgreSQL (SQLite suffices)
- No Forgejo federation
- No builds for other repos yet (MCP server only, extend later)
