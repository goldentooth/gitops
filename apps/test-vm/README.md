## Test VM Example

This demonstrates the immutable VM pattern for Goldentooth.

### How it works

1. **DataVolume** (`ubuntu-test-disk`) automatically imports Ubuntu 24.04 from a container image
2. **VirtualMachine** uses that DataVolume as its root disk
3. CloudInit provides initial configuration (username/password)

### Usage

```bash
# Start the VM
kubectl patch vm ubuntu-test-vm -n kubevirt --type merge -p '{"spec":{"running":true}}'

# Check status
kubectl get vm -n kubevirt
kubectl get vmi -n kubevirt  # VirtualMachineInstance

# Connect to console
virtctl console ubuntu-test-vm -n kubevirt

# Login: ubuntu/ubuntu

# Stop the VM
kubectl patch vm ubuntu-test-vm -n kubevirt --type merge -p '{"spec":{"running":false}}'

# Delete everything
kubectl delete vm ubuntu-test-vm -n kubevirt
kubectl delete dv ubuntu-test-disk -n kubevirt
```

### For production VMs

**Pin to specific node** (like velaryon):
```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: velaryon
      tolerations:
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
```

**Use golden images** built with Packer:
```yaml
spec:
  source:
    http:
      url: "https://my-images.example.com/slurm-compute-v1.0.0.qcow2"
```

Or **clone from existing PVC**:
```yaml
spec:
  source:
    pvc:
      name: golden-slurm-image
      namespace: kubevirt
```
