#!/usr/bin/env bash
#
# reflash-fleet.sh — stage the EEPROM TFTP_IP migration (10.4.0.30 -> 10.4.11.30)
# across the Pi fleet, one node at a time.
#
# For each target it renders the right Job (Pi 4B -> eeprom-update-job.yaml,
# Pi 5 -> eeprom-update-pi5-job.yaml) with the node name substituted, applies it,
# waits for completion, prints the logs, then tells YOU the reboot command. It
# does NOT auto-reboot — firmware flashes happen on reboot and you want to watch
# each node come back on the new anchor before moving on.
#
# The node->model map mirrors node-inventory.yaml (keep in sync). velaryon (x86)
# has no Pi EEPROM and is intentionally absent.
#
# Usage:
#   ./reflash-fleet.sh <node>        # stage one node (canary / targeted)
#   ./reflash-fleet.sh list          # show the fleet + models
#   ./reflash-fleet.sh all           # walk every node, pausing for you to
#                                     #   reboot+verify between each
#
# Requires: kubectl (context = the cluster). Reboots are manual:
#   Talos (Pi 4B): talosctl -n <ip> reboot
#   Ubuntu (Pi 5): ssh <node> sudo reboot   (or cordon/drain + reboot)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="netboot"

# hostname:model:ip — from node-inventory.yaml
FLEET=(
  "allyrion:pi4b:10.4.0.10"
  "bettley:pi4b:10.4.0.11"
  "cargyll:pi4b:10.4.0.12"
  "dalt:pi4b:10.4.0.13"
  "erenford:pi4b:10.4.0.14"
  "fenn:pi4b:10.4.0.15"
  "gardener:pi4b:10.4.0.16"
  "harlton:pi4b:10.4.0.17"
  "inchfield:pi4b:10.4.0.18"
  "jast:pi4b:10.4.0.19"
  "karstark:pi4b:10.4.0.20"
  "lipps:pi4b:10.4.0.21"
  "manderly:pi5:10.4.0.22"
  "norcross:pi5:10.4.0.23"
  "oakheart:pi5:10.4.0.24"
  "payne:pi5:10.4.0.25"
)

lookup() { # $1=node -> echoes "model:ip" or empty
  local entry
  for entry in "${FLEET[@]}"; do
    case "${entry}" in
      "${1}:"*) echo "${entry#*:}"; return 0 ;;
    esac
  done
  return 1
}

stage_node() { # $1=node
  local node="$1" meta model ip job
  if ! meta="$(lookup "${node}")"; then
    echo "ERROR: '${node}' is not in the fleet map (velaryon has no Pi EEPROM)." >&2
    return 1
  fi
  model="${meta%%:*}"
  ip="${meta##*:}"
  case "${model}" in
    pi4b) job="${HERE}/eeprom-update-job.yaml" ;;
    pi5)  job="${HERE}/eeprom-update-pi5-job.yaml" ;;
    *)    echo "ERROR: unknown model '${model}' for ${node}" >&2; return 1 ;;
  esac

  echo "=== staging EEPROM update on ${node} (${model}, ${ip}) ==="
  # Clean any prior run (Jobs are immutable + share a fixed name).
  kubectl -n "${NS}" delete job -l "app in (eeprom-update)" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS}" delete job eeprom-update eeprom-update-pi5 --ignore-not-found >/dev/null 2>&1 || true

  sed "s/__TARGET_NODE__/${node}/" "${job}" | kubectl apply -f -

  local jobname
  jobname="$(basename "${job}" .yaml | sed 's/-job$//')"   # eeprom-update | eeprom-update-pi5
  echo "waiting for Job/${jobname} to complete (up to 10m)..."
  if ! kubectl -n "${NS}" wait --for=condition=complete "job/${jobname}" --timeout=600s; then
    echo "Job did not complete — logs:" >&2
    kubectl -n "${NS}" logs "job/${jobname}" || true
    return 1
  fi
  kubectl -n "${NS}" logs "job/${jobname}" | tail -20

  echo
  echo ">>> ${node}: EEPROM update STAGED. Now reboot it to flash, then verify it"
  echo "    comes back on 10.4.11.30:"
  if [ "${model}" = "pi4b" ]; then
    echo "      talosctl -n ${ip} reboot"
  else
    echo "      ssh ${node} sudo reboot   # (Ubuntu; cordon/drain first if you prefer)"
  fi
  echo "    Then: kubectl get node ${node} -w   (wait for Ready)"
}

case "${1:-}" in
  list)
    printf '%-12s %-6s %s\n' NODE MODEL IP
    for e in "${FLEET[@]}"; do IFS=: read -r n m i <<<"${e}"; printf '%-12s %-6s %s\n' "${n}" "${m}" "${i}"; done
    ;;
  all)
    echo "Walking the whole fleet. After each node is STAGED you must reboot +"
    echo "verify it before continuing (un-reflashed nodes still need the old"
    echo "10.4.0.30 server up — see HA-MIGRATION.md)."
    for e in "${FLEET[@]}"; do
      node="${e%%:*}"
      stage_node "${node}"
      read -r -p "Rebooted ${node} and confirmed Ready on 10.4.11.30? [enter to continue / Ctrl-C to stop] "
    done
    echo "Fleet staged."
    ;;
  ""|-h|--help)
    sed -n '2,30p' "${BASH_SOURCE[0]}"
    ;;
  *)
    stage_node "$1"
    ;;
esac
