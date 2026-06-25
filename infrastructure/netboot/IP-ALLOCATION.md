# Netboot IP allocation

## The `10.4.0.0/9` reserved (infrastructure) range

`10.4.0.0/20` is the infra subnet (mask `255.255.240.0`). Addresses **`10.4.0.0`–`10.4.0.9`**
are reserved for fixed infrastructure and **excluded from the UniFi DHCP pool**, so they
never collide with a lease. Current allocation:

| Address | Owner | Notes |
|---|---|---|
| `10.4.0.1` | UniFi gateway | `unifi.local` |
| `10.4.0.2`–`10.4.0.7` | _free_ | reserved, unassigned |
| **`10.4.0.8`** | **netboot VIP** | floating TFTP + matchbox anchor (this doc) |
| `10.4.0.9` | Talos control-plane VIP | `machine.network.interfaces.vip` (API server) |

Node IPs (`10.4.0.10`–`10.4.0.25`, see `node-inventory.yaml`) and velaryon (`10.4.0.30`)
live outside this reserved block.

> If you change the reserved range or the DHCP pool start, update this table **and** the
> UniFi DHCP exclusion so `10.4.0.8` stays unassignable.

## Why `10.4.0.8` is a dedicated, *floating* VIP (not velaryon's IP, not MetalLB)

The 2026-06 outage exposed two hard constraints on the netboot service:

1. **TFTP cannot go through a NAT/LoadBalancer VIP.** A MetalLB `LoadBalancer` IP DNATs to
   the pod; TFTP's data transfer uses an ephemeral port that cilium has no conntrack helper
   for, so replies come back from the pod IP → clients reject them (`received packet from
   wrong source`). TFTP only works when served from a real host IP with **no NAT** —
   i.e. `hostNetwork`. So the netboot VIP must be an **ARP-floated host IP**
   (kube-vip), *not* a MetalLB IP. (matchbox is HTTP and *could* use MetalLB, but we
   co-locate it on the same anchor for clarity.)

   > **Float mechanism = kube-vip, not keepalived.** keepalived (VRRP) was tried first and
   > split-brained — VRRP (IP proto 112) is not delivered host-to-host in this cluster
   > (every node became MASTER, even with unicast peers + distinct priorities + working
   > ICMP). kube-vip elects the holder via a Kubernetes `Lease` (over the API → no
   > proto-112) and gratuitous-ARPs the VIP onto the leader (ARP works here). Validated
   > 2026-06-25 (`validation/`): TFTP-from-VIP + clean failover both pass.

2. **The anchor must survive losing any one node.** The old design pinned everything to
   velaryon (`10.4.0.30` = its node IP), so velaryon dying took down all netboot and the
   cluster couldn't re-boot its Talos nodes. The anchor therefore has to **float** across
   the disk-booting nodes.

Two ways to get a floating anchor were considered:

- **Float `10.4.0.30` in place** — no EEPROM reflash, but requires changing velaryon's node
  IP (delicate, ripples) and a *risky in-place cutover* (same IP can't run old + new at
  once → there's a window where nothing serves).
- **Dedicated new VIP `10.4.0.8` (chosen).** velaryon keeps `10.4.0.30` and keeps serving
  the *whole* migration; `10.4.0.8` comes up in parallel on a different address (no
  conflict); Pis are reflashed `TFTP_IP 10.4.0.30 → 10.4.0.8` one at a time, each falling
  back to the still-live `10.4.0.30` if its reflash fails. **No stranding window.** The cost
  is the one-time fleet EEPROM reflash — but done safely, with coexistence and easy fallback.

## Target architecture (Design B2)

- **kube-vip** (ARP + Kubernetes `Lease` election) DaemonSet on the disk-booting workers
  (manderly/norcross/payne) floats **`10.4.0.8`**. Only the lease leader holds it; it fails
  over on node loss (validated).
- **dnsmasq** `hostNetwork` DaemonSet on the same nodes, `bind-dynamic`, answers TFTP from
  `10.4.0.8` on whichever node currently holds the VIP (no NAT → TFTP works).
- **matchbox** served on `10.4.0.8:8080` (HTTP); `grub.cfg`'s `talos.config=` points there.
- **Pi EEPROM `TFTP_IP` = `10.4.0.8`** (reflashed from `10.4.0.30`).

Netboot then depends only on *the disk-booting nodes* (which never netboot themselves), with
no single point of failure — instead of a single velaryon.

The load-bearing unknowns were validated 2026-06-25 in `validation/` (kube-vip + dnsmasq at
a test `10.4.0.8`, zero production impact): `hostNetwork`+`bind-dynamic` dnsmasq replies to
TFTP *from* the floating VIP, and kube-vip fails the VIP over cleanly on leader loss. Both
pass — so the architecture is proven before any Pi or velaryon change.
