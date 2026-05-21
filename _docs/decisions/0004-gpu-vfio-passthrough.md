# ADR-0004: GPU access via single-node VFIO passthrough (not SR-IOV)

- **Status:** Proposed — recommendation drafted, pending hardware validation. Not implemented.
- **Date:** 2026-05-18
- **Deciders:** fr3d (with terraform-specialist agent)
- **Related:** [ADR-0005](0005-thoth-knowledge-app.md) (Thoth's AI layer is the likely second GPU consumer).

## Context

The lab has no discrete GPU — every Proxmox host is a mini-PC with an integrated Intel iGPU only (6× Beelink S13 = Alder Lake-N N100/N150 Gen12 Xe-LP with Quick Sync; 1× HP Slim S01, iGPU class TBD). A Jellyfin-class media server needs hardware transcoding inside a Talos VM scheduled by Kubernetes. Talos is immutable — GPU kernel modules ship as `siderolabs` system extensions baked into the image at factory.talos.dev. The real question: share one iGPU across multiple VMs (SR-IOV) or hand one iGPU to a single node and "share" at the Kubernetes scheduler.

## Decision

**Start with single-node VFIO PCI passthrough on the HP Slim S01.** Kubernetes handles "sharing" at the scheduler via the Intel GPU device plugin's `shared-dev-num` fractional allocation; transcoding pods pin to the GPU node via nodeAffinity.

## Rationale

| Option | Verdict |
| --- | --- |
| **VFIO passthrough (single VM)** on HP Slim | **Chosen.** Standard, works today. HP Slim sits outside the Beelink quorum, so dedicating it costs no control-plane/worker capacity. Avoids dkms entirely. |
| Intel SR-IOV (`i915-sriov-dkms`) | The only true multi-VM share, but ADL-N support is "community mixed/unstable," out-of-tree, and breaks on every Proxmox kernel bump. High ongoing burden. |
| Intel GVT-g | Dead end — removed from i915 for Gen12+. |
| LXC bind-mount `/dev/dri` | N/A — Talos is a VM, not LXC. |

Jellyfin needs only one transcoding target; the device plugin already does fractional sharing. **Revisit SR-IOV only if** a second GPU-bound workload (Immich ML, Frigate, Thoth AI) appears and contention on one node becomes real.

## Consequences

**Positive**
- No dkms maintenance treadmill; standard Proxmox `hostpci` flow.
- The GPU node is expendable to the cluster (outside quorum).

**Negative / trade-offs**
- Only one node sees the GPU — all GPU workloads must be schedulable there.
- Extension changes mean a Talos **re-image**, not a hot reload — test on one node before fleet rollout.

**Open validation items (before this becomes Accepted):**
- Confirm HP Slim iGPU generation + Quick Sync codec matrix (`lspci | grep VGA` on the host).
- Verify the pinned `bpg/proxmox` provider in `terraform/dev/talos-pve-v3.1.0/` supports `hostpci` with `pcie`/`mdev`.
- Pick exact Talos extensions (`siderolabs/i915-ucode` ± `siderolabs/intel-ucode`).
- The Intel device-plugin pod runs privileged → will collide with the Kyverno `add-default-securitycontext` `runAsUser→65534` mutation unless an explicit allowlist entry is added.

## References

- Full decision essay (archived): `archive/source-docs/gpu-sharing-decision.md`
