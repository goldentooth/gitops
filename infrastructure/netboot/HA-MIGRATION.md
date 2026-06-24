# Netboot HA migration (dnsmasq + matchbox) — Option A

**Why:** the 2026-06 outage. `dnsmasq` (TFTP) and `matchbox` (Talos config) were
single instances `hostNetwork`-pinned to **velaryon**, served at velaryon's host
IP **10.4.0.30**. When velaryon died, all netboot died with it, every Talos Pi
that rebooted got stuck at PXE ("steady amber"), and power-cycling couldn't fix
it (circular dependency: nodes need netboot to boot; netboot lived on one node).

**The fix:** make the netboot services HA behind a **floating MetalLB VIP**, run
them only on disk-booting nodes (so netboot never again depends on a node that
itself netboots), and move the PXE boot *options* to the always-on UniFi DHCP.

**Anchor IP change (the crux):** `10.4.0.30` is velaryon's host IP and is outside
the MetalLB pool, so it can't be floated. We move the anchor to **`10.4.11.30`**
(a free IP inside the MetalLB pool `10.4.11.0–10.4.15.254`) and **reflash every
Pi EEPROM's `TFTP_IP` 10.4.0.30 → 10.4.11.30** (Option A). `TFTP_IP` is set
statically in EEPROM; a *future* anchor move would need another reflash.

What this branch changes: `dnsmasq` DaemonSet→Deployment (2 replicas, anti-affinity
across velaryon/manderly/norcross/payne, TFTP-only) behind `dnsmasq-tftp` VIP;
`matchbox` 1→2 replicas, no hostNetwork, behind its VIP (corrected to 10.4.11.30);
both VIPs share 10.4.11.30 via MetalLB `allow-shared-ip`; proxy-DHCP removed from
dnsmasq (→ UniFi); EEPROM jobs + boot cmdline retargeted to 10.4.11.30.

## Fleet (from node-inventory.yaml) — 16 Pis to reflash

- **Pi 4B (BCM2711), Talos** → `eeprom-update-job.yaml`: allyrion, bettley,
  cargyll, dalt, erenford, fenn, gardener, harlton, inchfield, jast, karstark, lipps
- **Pi 5 (BCM2712)** → `eeprom-update-pi5-job.yaml`: manderly, norcross, payne, oakheart

velaryon (x86) has no Pi EEPROM. Driver: `./reflash-fleet.sh` (`list` / `<node>` / `all`).

---

## Prerequisites

- **Cluster fully recovered** on the CURRENT (old, 10.4.0.30/velaryon) setup —
  all 16 Pis Ready. Do NOT migrate mid-outage; a node must be UP to reflash it.
- `10.4.11.30` is free: `kubectl get svc -A -o wide | grep 10.4.11.30` → empty.
- MetalLB has an L2Advertisement covering the pool (it already serves 10.4.11.x).
- `kubectl` context = the cluster; `talosctl` configured for the Pi 4B nodes.

## Rollout (phased — ordering is safety-critical)

### Phase 0 — prep, no disruption
Confirm prerequisites. Leave the old setup running.

### Phase 1 — cut over the in-cluster services (maintenance window)
Merge this branch → flux applies the final state: old velaryon daemonset removed,
the `10.4.11.30` VIP + HA pods come up. **Running nodes keep running** (they only
re-read netboot on reboot), so this is low-impact, but from here until a node is
reflashed it must NOT reboot (its EEPROM still points at the now-gone 10.4.0.30).

Validate the VIP before touching any Pi:
```bash
kubectl -n netboot get deploy,pods -o wide        # 2 dnsmasq + 2 matchbox on ≥2 disk-booting nodes
kubectl -n netboot get svc                          # dnsmasq-tftp + matchbox both EXTERNAL-IP 10.4.11.30
tftp 10.4.11.30 -c get pxelinux.0 /tmp/x && ls -l /tmp/x
curl -s -o /dev/null -w '%{http_code}\n' http://10.4.11.30:8080/
```
**Rollback if the VIP is broken:** `git revert` the merge → old 10.4.0.30 setup
returns. No node has rebooted, so nothing is stranded.

> ⚠️ Window risk: while migrating, an *un-reflashed* node that reboots for any
> reason can't netboot (EEPROM still says 10.4.0.30, which is gone). Mitigation:
> do the fleet promptly and don't reboot nodes except the one you're reflashing.
> If you want zero window risk, keep velaryon's old hostNetwork dnsmasq running in
> parallel until Phase 3 (run the new stack under temporary `-ha` labels to avoid
> the `app: dnsmasq` selector collision) — more fiddly; usually not worth it here.

### Phase 2 — canary reflash
Pick one non-control-plane Pi 4B (e.g. `lipps`):
```bash
./reflash-fleet.sh lipps          # stages the EEPROM update Job, waits, prints reboot cmd
talosctl -n 10.4.0.21 reboot      # flashes EEPROM on boot
kubectl get node lipps -w         # must come back Ready — proves it netbooted via 10.4.11.30
```
If it fails: the old 10.4.0.30 path is gone, so recover by re-staging with
`TFTP_IP=10.4.0.30` (revert Phase 1) — hence validate the VIP in Phase 1 first.

### Phase 3 — fleet reflash
```bash
./reflash-fleet.sh all            # walks every node; pauses for you to reboot+verify each
```
One node at a time. **Do control-plane nodes individually, waiting for Ready
between**, to preserve etcd quorum. Never reboot an un-reflashed node.

### Phase 4 — finish + UniFi
- Set UniFi DHCP boot options for `10.4.0.0/20`: **next-server `10.4.11.30`**,
  **boot filename `pxelinux.0`** (covers the Pi 4B EDK2/GRUB chain now that
  in-cluster proxy-DHCP is gone). Pi 5 / VideoCore uses its reflashed EEPROM
  `TFTP_IP` directly and ignores DHCP boot options.
- Verify a full reboot of a node netboots cleanly via the VIP.
- **Failover test:** drain/poweroff whichever node currently announces 10.4.11.30
  (`kubectl -n netboot get svc dnsmasq-tftp -o wide` → check the node), confirm the
  VIP + a dnsmasq/matchbox replica move to another disk-booting node and a node can
  still netboot. This is the whole point — confirm it works.

## Validation summary
```bash
kubectl -n netboot get deploy,svc,pods -o wide
tftp 10.4.11.30 -c get pxelinux.0 /tmp/x && echo TFTP-OK
curl -s -o /dev/null -w 'matchbox %{http_code}\n' http://10.4.11.30:8080/
kubectl get nodes        # all 16 Ready
```

## Rollback
- **Before any reflash:** `git revert` the merge → old velaryon 10.4.0.30 setup.
- **After reflashing some nodes:** they now expect 10.4.11.30. To fully roll back
  you'd re-stage those nodes with `TFTP_IP=10.4.0.30` and revert the merge. Easier
  to roll *forward* — finish the fleet.

## Notes / tech-debt
- The EEPROM jobs pull `rpi-eeprom@master` from GitHub at run time — pin a ref for
  reproducibility before a future re-run.
- `reflash-fleet.sh` stages only; reboots are manual (one node at a time, watched).
- Longer term, the disk-booting-node constraint is expressed via explicit hostname
  affinity; a `goldentooth.io/netboot-server` node label (set in Talos/Ansible) is
  the cleaner selector.
