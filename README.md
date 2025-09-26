# Goldentooth GitOps

GitOps repository for the Goldentooth Talos Kubernetes cluster.

## Structure

```
├── clusters/goldentooth/          # Cluster-specific configuration
│   ├── flux-system/               # Flux system components (managed by bootstrap)
│   ├── infrastructure.yaml        # Infrastructure Kustomization
│   └── apps.yaml                  # Applications Kustomization
├── infrastructure/                # Infrastructure components
│   ├── base/                      # Reusable infrastructure components
│   │   ├── namespaces/            # Common namespaces
│   │   ├── storage/               # Storage classes, PVCs
│   │   ├── networking/            # CNI, ingress, load balancer
│   │   └── monitoring/            # Prometheus, Grafana
│   └── goldentooth/               # Cluster-specific infrastructure
└── apps/                          # Applications
    ├── base/                      # Reusable application components
    └── goldentooth/               # Cluster-specific applications
```

## Deployment Flow

1. **Infrastructure** components are deployed first (networking, storage, monitoring)
2. **Applications** are deployed after infrastructure is ready
3. **SOPS** is used for secret encryption
4. **Wave annotations** control deployment order within each phase

## Secret Management

Secrets are encrypted using SOPS with Age encryption:
- Age public key is stored in `.sops.yaml`
- Private key is stored in Kubernetes secret `sops-age` in `flux-system` namespace

## Talos Integration

This repository manages a Talos Linux Kubernetes cluster with:
- 3 control plane nodes (allyrion, bettley, cargyll)
- 9 worker nodes (dalt through lipps)
- Kubernetes v1.34.0
- Flannel CNI