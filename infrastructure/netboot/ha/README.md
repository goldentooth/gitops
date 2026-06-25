# Production HA netboot (Design B2) — manifests + migration runbook

**Status: REVIEW.** `ha/` is deliberately **not** in `../kustomization.yaml`, so flux ignores
it. Nothing here is applied until we promote it per the steps below.

Validated end-to-end 2026-06-25 (`../validation/`): kube-vip floats `10.4.0.8` via a k8s
Lease (no proto-112), hostNetwork dnsmasq serves TFTP **from** the VIP (no NAT), clean
failover. Rationale + IP table: `../IP-ALLOCATION.md`.

## What's here
- `kube-vip.yaml` — SA/RBAC + DaemonSet, floats `10.4.0.8` on manderly/norcross/payne.
- `dnsmasq.yaml` — hostNetwork TFTP DaemonSet, `bind-dynamic` on `10.4.0.8` (TFTP-only).
- `matchbox.yaml` — hostNetwork DaemonSet, VIP-holder answers `10.4.0.8:8080`.

End state: netboot depends on the disk-booting Pi5 workers (never themselves netboot), with
no single point of failure — replacing the single velaryon.

## Migration — additive & parallel (no stranding window)

velaryon keeps serving `10.4.0.30` the **entire** time; the new stack comes up on `10.4.0.8`
(different IP → no conflict). Each Pi is reflashed `TFTP_IP 10.4.0.30 → 10.4.0.8` one at a
time; a Pi whose reflash fails still boots via the live `10.4.0.30`.

0. **Pre:** cluster healthy (✓), validation passed (✓).
1. **matchbox first.** Apply `matchbox.yaml` so `10.4.0.8:8080` serves before any grub.cfg
   points at it. Then change the matchbox URL baked into grub.cfg —
   `setup-boot-assets-script.yaml`: `talos.config=http://10.4.0.30:8080` → `http://10.4.0.8:8080`.
   (Shared script; both stacks then point at `10.4.0.8` matchbox, which is up — safe for old
   and new Pis during the parallel phase.)
2. **VIP + TFTP.** Apply `kube-vip.yaml` + `dnsmasq.yaml`. Verify (same as the canary):
   `kubectl -n netboot get lease netboot-vip`; `tftp 10.4.0.8 -c get pxelinux.0 /tmp/x`;
   kill the leader → VIP + TFTP fail over. velaryon's `10.4.0.30` is untouched throughout.
3. **UniFi DHCP — TEMPORARY bootstrap** (for the Pi4 EDK2 stage-2). `next-server = 10.4.0.8`,
   boot filename `pxelinux.0` (already set 2026-06-25). Non-disruptive (Pi VideoCore uses its
   EEPROM `TFTP_IP`; only EDK2 reads next-server). When set, **disable velaryon's proxy-DHCP**
   (`dnsmasq-configmap.yaml` — drop the `dhcp-range/dhcp-boot/pxe-service` lines) so there's a
   single boot-pointer source. This manual UniFi setting is replaced by in-cluster proxy-DHCP
   in step 7 (the IaC end-state).
4. **Reflash target = `10.4.0.8`.** In `../eeprom-update-job.yaml` + `../eeprom-update-pi5-job.yaml`
   set `TFTP_IP=10.4.0.8`. Canary one worker: `../reflash-fleet.sh lipps`, `talosctl reboot`,
   confirm it netboots via `10.4.0.8` and rejoins (fallback: re-stage with `10.4.0.30`).
5. **Fleet.** `../reflash-fleet.sh all` — one node at a time, control-plane (allyrion/
   bettley/cargyll) individually for quorum. 16 Pis total (12 Pi4 + 4 Pi5).
6. **Retire `10.4.0.30`.** Once all 16 are on `10.4.0.8`: remove the velaryon-pinned
   `dnsmasq-daemonset.yaml`, `matchbox-deployment.yaml`, `matchbox-service.yaml` from
   `../kustomization.yaml` and add `ha/*`. Done — single SPOF gone.
7. **IaC boot pointer (replace the UniFi `next-server`).** Uncomment the proxy-DHCP block in
   `dnsmasq.yaml`, then **remove** the UniFi `next-server` (only one source may answer).
   Validate by rebooting one **Pi4** through EDK2 — if it netboots, the boot pointer is now
   fully in gitops; delete the UniFi setting for good. If the Pi4 firmware is picky about the
   3-responder DaemonSet, fall back to a **single-replica** proxy-DHCP responder (replicas:1
   Deployment with the same 3 directives). Pi5 + all VideoCore stages are unaffected (EEPROM
   `TFTP_IP`). Roll back trivially by re-commenting + restoring the UniFi setting.

## Open decisions for review
1. **proxy-DHCP responder shape (step 7).** Default is proxy-DHCP on the dnsmasq DaemonSet
   (3 responders) — simplest, HA, but unproven vs these Pi4 EEPROMs. Real test = a Pi4 EDK2
   reboot. Fallback if picky = single-replica responder (IaC, slower failover, only consulted
   at EDK2 boot). UniFi `next-server` is the working bootstrap until this is proven.
2. **Reflash the Pi5 server nodes too?** manderly/norcross/payne/oakheart boot Ubuntu from
   disk; their `TFTP_IP` is only a fallback. Recommend reflashing them too for consistency.
3. **matchbox `:8080` on the Pi5 hosts** — confirm host port 8080 is free on manderly/
   norcross/payne (hostNetwork).
4. **kube-vip** pinned to `v0.8.7` (validated). `vip_interface=eth0` assumes all float nodes
   are Pi5/eth0 (true for manderly/norcross/payne).
5. **Wiring:** promote either by adding `ha/*` to `../kustomization.yaml` (flux) or
   `kubectl apply -f ha/` for step 2 while iterating. The retire step (6) is the kustomization edit.
