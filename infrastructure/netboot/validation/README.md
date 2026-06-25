# Netboot VIP validation (Design B2) — RESULTS: PASSED (2026-06-25)

Validated the load-bearing unknowns for a floating netboot VIP, with **zero production
impact** (isolated `netboot-validation` namespace, Pi5 workers manderly/norcross/payne,
TFTP-only, test VIP `10.4.0.8`, no Pi/velaryon/flux touched).

## Outcome

| Check | Result |
|---|---|
| TFTP served **from** the floating VIP (`hostNetwork`+`bind-dynamic`, no NAT) | ✅ full 614400 B, no `wrong source` |
| Single holder of `10.4.0.8` (no split-brain) | ✅ (kube-vip lease leader) |
| Failover — kill leader, VIP + TFTP move | ✅ lease + VIP moved norcross→payne, TFTP OK |

**Float mechanism: kube-vip, not keepalived.** keepalived (VRRP) was tried first and
**split-brained** — VRRP (IP proto 112) isn't delivered host-to-host in this cluster (every
node became MASTER, even with unicast peers + distinct priorities + working ICMP). kube-vip
elects via a Kubernetes `Lease` (over the API → no proto-112) and gratuitous-ARPs the VIP
(ARP works here). The dnsmasq TFTP half was unchanged and worked under both.

## How it was run

```bash
kubectl apply -f infrastructure/netboot/validation/    # ns + dnsmasq-tftp + kube-vip
kubectl -n netboot-validation get lease netboot-vip -o jsonpath='{.spec.holderIdentity}'   # leader
tftp 10.4.0.8 -c get pxelinux.0 /tmp/x && ls -l /tmp/x  # Test 1: full file, no "wrong source"
# Test 2 (failover):
kubectl -n netboot-validation delete pod -l app=kube-vip --field-selector spec.nodeName=<leader>
sleep 20 && tftp 10.4.0.8 -c get pxelinux.0 /tmp/x2 && ls -l /tmp/x2   # still serves
```

Teardown: `kubectl delete ns netboot-validation`.

## Next: promote to production (separate, reviewed change in the `netboot` namespace)

1. kube-vip (ARP + lease) + `hostNetwork` dnsmasq DaemonSet at `10.4.0.8` on the disk-booting
   nodes, **in parallel** with velaryon's live `10.4.0.30` (different IP → no conflict).
   matchbox on `10.4.0.8:8080`; `grub.cfg` `talos.config` → `10.4.0.8`.
   - Production interface note: validation pinned `vip_interface=eth0` (all Pi5). Keep the
     float on the Pi5 workers (manderly/norcross/payne) so `eth0` holds; velaryon needn't be
     a float node.
2. Canary-reflash one worker (lipps) `TFTP_IP → 10.4.0.8`; `10.4.0.30` is the fallback.
3. Reflash the fleet (`../reflash-fleet.sh`, retargeted to `10.4.0.8`), one node at a time.
4. Retire velaryon's `10.4.0.30` netboot once all 16 are on `10.4.0.8`.
