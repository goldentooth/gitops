# Netboot HA migration (dnsmasq + matchbox)

**Why:** the 2026-06 outage. `dnsmasq` and `matchbox` were single instances
`hostNetwork`-pinned to **velaryon**. When velaryon went down it took the whole
bramble's netboot (DHCP-PXE + TFTP + Talos config) with it, so every Talos node
that rebooted got stuck at PXE (link up, no OS — "steady amber") and **could not
be recovered by power-cycling** — a circular dependency (nodes need netboot to
boot; netboot lived on one node).

**What changed (this branch):**

| | Before | After |
|---|---|---|
| dnsmasq | DaemonSet, `hostNetwork`, pinned to velaryon, proxy-DHCP + TFTP | Deployment, 2 replicas, anti-affinity across **disk-booting** nodes, **TFTP-only**, behind a floating VIP |
| matchbox | Deployment, 1 replica, `hostNetwork`, pinned to velaryon | Deployment, 2 replicas, anti-affinity, behind a floating VIP |
| 10.4.0.30 | velaryon's host IP (dies with the node) | **MetalLB L2 VIP**, shared by both Services, fails over on node death |
| PXE boot options | dnsmasq proxy-DHCP (broadcast → needs hostNetwork → can't be HA) | **UniFi DHCP** (always-on) |

`10.4.0.30` is immutable: the Pi EEPROMs hardcode `TFTP_IP=10.4.0.30`
(`eeprom-update*.yaml`) and the Talos cmdline targets `http://10.4.0.30:8080`
(`setup-boot-assets-script.yaml`). We keep that IP but make it float.

Netboot now only ever runs on nodes that boot from local disk
(velaryon + the Ubuntu workers manderly/norcross/payne), so it never again
depends on a node that itself needs netboot.

---

## REQUIRED manual step — UniFi DHCP (do this FIRST)

Removing in-cluster proxy-DHCP means the **PXE boot options must come from UniFi**
for Pi 4 (EDK2 UEFI) nodes. On the UniFi controller, for the `10.4.0.0/20`
network:

- Network boot / PXE: **enabled**
- **TFTP server / next-server: `10.4.0.30`**
- **Boot filename: `pxelinux.0`**

(Pi 5 / VideoCore EEPROM netboot ignores DHCP boot options — it uses its
hardcoded `TFTP_IP=10.4.0.30` + serial subdir — so it only needs a lease + TFTP
at 10.4.0.30, which still hold. So if your fleet is Pi 5-only you can technically
skip the boot-filename, but set it anyway for the EDK2 path.)

> ⚠️ **Ordering matters.** If you `flux`-apply this branch *before* setting the
> UniFi options, Pi 4 EDK2 nodes lose their PXE boot options (no proxy-DHCP, no
> UniFi next-server yet) and won't netboot. **Set UniFi first, verify a node can
> still PXE, then merge.** Don't do this while the cluster is still in the
> degraded state from the outage — finish recovery first.

---

## Rollout order

1. **Recover the cluster first** (velaryon back, nodes Ready) — do NOT migrate
   netboot mid-outage.
2. Set the **UniFi DHCP options** above. Verify the MetalLB pool includes
   `10.4.0.30` (it must be allocatable as an L2 VIP on the 10.4.0.0/20 segment;
   if your MetalLB pool is only 10.4.11.0–10.4.15.254, add a pool/range covering
   10.4.0.30 or move the anchor IP — see "Open question" below).
3. Merge this branch → flux reconciles `infrastructure/netboot`.
4. Validate (below).
5. Test a real reboot of one Talos node and confirm it netboots.
6. **Failover test:** cordon/`drain` (or power off) whichever node currently
   announces `10.4.0.30`, confirm the VIP + a dnsmasq/matchbox replica move to
   another disk-booting node and a node can still netboot.

## Validation

```bash
kubectl -n netboot get deploy,pods -o wide        # 2 dnsmasq + 2 matchbox, on ≥2 distinct disk-booting nodes
kubectl -n netboot get svc                          # dnsmasq-tftp + matchbox both EXTERNAL-IP 10.4.0.30
# TFTP reachable on the VIP:
tftp 10.4.0.30 -c get pxelinux.0 /tmp/x && ls -l /tmp/x
# matchbox reachable on the VIP:
curl -s http://10.4.0.30:8080/ -o /dev/null -w '%{http_code}\n'
```

## Rollback

`git revert` the merge (restores the velaryon-pinned DaemonSet/Deployment) and
remove the UniFi next-server/filename options. Because `10.4.0.30` is unchanged
in both states, rollback doesn't require touching the Pi EEPROMs.

---

## ⚠️ BLOCKER to resolve before merge — the anchor IP (10.4.0.30)

Confirmed from the repo: the MetalLB pool (`apps/metallb.yaml`) is
**`10.4.11.0–10.4.15.254`**. **`10.4.0.30` is NOT in it** — it's on the node
subnet and is currently **velaryon's own static host IP** (that's how the old
hostNetwork setup served it). You cannot float a node's host IP as a MetalLB VIP:
when velaryon is up it would conflict with the VIP. So the Service manifests in
this draft (loadBalancerIP 10.4.0.30) **won't get an address as-is** — pick one
of these first:

**Option A — move the anchor into the MetalLB pool (cleanest; one-time EEPROM
reflash).** Choose a free pool IP (e.g. `10.4.11.30`) and update everything that
hardcodes the anchor:
  - `dnsmasq-service.yaml` + `matchbox-service.yaml` loadBalancerIP/annotation
  - `setup-boot-assets-script.yaml` cmdline `talos.config=http://<ip>:8080`
  - `eeprom-update-job.yaml` + `eeprom-update-pi5-job.yaml` `TFTP_IP`
  - UniFi `next-server`
  Then re-run the eeprom-update jobs on every Pi (reflashes `TFTP_IP`). Permanent,
  fully in-pool VIP HA. Cost: an EEPROM reflash pass (do it once, cluster healthy).

**Option B — keep 10.4.0.30, carve it out as a dedicated single-IP MetalLB pool
+ free it from velaryon.** Add an `IPAddressPool` for `10.4.0.30/32`
(+ L2Advertisement) and change **velaryon's static host IP** (Talos machine
config) to something else so the VIP can own `10.4.0.30`. No EEPROM reflash, but
you must edit velaryon's node config and ensure 10.4.0.30 is reserved/excluded in
UniFi DHCP. Confirm 10.4.0.30 isn't otherwise in a DHCP range.

I drafted the Services pinned to `10.4.0.30` (Option B shape) since it avoids
touching EEPROMs, but **Option A is the more robust long-term answer.** Tell me
which and I'll finalize the manifests (+ the MetalLB pool resource).

- **`allow-shared-ip`.** Both Services share the anchor IP via
  `metallb.universe.tf/allow-shared-ip: netboot-anchor` (different ports/protocols
  → allowed). Verify your MetalLB version honors the annotation (v0.13+).
