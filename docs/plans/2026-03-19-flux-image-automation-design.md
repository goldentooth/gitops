# Flux Image Auto-Deploy Design

**Goal:** Automatically deploy new MCP server Docker images when CI builds complete, using Flux image automation with timestamp-prefixed SHA tags.

## Architecture

```
GitHub push → Forgejo mirror → CI builds image →
tags: <timestamp>-<short-sha>, latest → registry →
ImageRepository scans → ImagePolicy selects newest →
ImageUpdateAutomation commits new tag to gitops →
Flux deploys updated Deployment
```

## Components

### 1. MCP Deployment in gitops (`apps/mcp/`)

Move MCP deployment manifests from the `mcp` repo into `gitops/apps/mcp/`. This matches the existing pattern (gatus, httpbin, jupyterlab all live under `apps/`). The deployment's image field gets a Flux image policy marker comment so the automation controller knows where to write updates.

### 2. ImageRepository (flux-system)

Scans `registry.goldentooth.net/goldentooth-mcp` every 1 minute for new tags. Needs TLS handling for the private Step-CA registry (either CA cert bundle or `insecure: true` for internal-only access).

### 3. ImagePolicy (flux-system)

Uses `numerical` extraction on the timestamp prefix to select the newest image. Tags follow the format `<unix-timestamp>-<short-sha>` (e.g., `1710886400-d53a7b8`). The `latest` tag is filtered out via regex.

### 4. ImageUpdateAutomation (flux-system)

Watches ImagePolicies and commits updated tags back to the gitops repo's `main` branch. Commit authored by Flux with a message like `chore(flux): update mcp image to <tag>`.

### 5. CI Workflow Update

Change the Forgejo Actions workflow to produce timestamp-prefixed tags instead of bare SHA tags:

```
--destination=registry.goldentooth.net/goldentooth-mcp:$(date +%s)-${GITHUB_SHA::8}
--destination=registry.goldentooth.net/goldentooth-mcp:latest
```

## Decisions

- **Tag strategy:** Timestamp-prefixed SHA (`<unix-ts>-<short-sha>`). SHA hashes aren't chronologically sortable, so the timestamp prefix gives Flux a numeric value to sort on.
- **Deployment location:** `gitops/apps/mcp/` (not in the mcp repo). Flux image automation commits tag updates to gitops, keeping all deployment config in one place.
- **Scan interval:** 1 minute for ImageRepository. Fast enough for a development workflow.
- **Every build deploys:** No gating, no approval. Every successful CI build on `main` gets deployed automatically. Appropriate for a single-developer project.

## Non-Goals

- Semver tagging (unnecessary complexity for now)
- Multi-environment promotion (only one cluster)
- Rollback automation (git revert is sufficient)
