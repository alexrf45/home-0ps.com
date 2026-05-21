# Shared GPU for Talos VMs on Proxmox — decision document

**Status:** Pre-decision. Research drafted; recommendation pending validation
of HP Slim S01 iGPU class and Proxmox PCI passthrough on the lab.
**Date:** 2026-05-18
**Author:** fr3d (with Claude / terraform-specialist agent)
**Scope:** GPU access strategy for future Kubernetes media-server workloads
(Jellyfin first; potential follow-ons Immich ML, Frigate). Covers both the
6-node Beelink S13 Proxmox cluster and the auxiliary HP Slim S01 host.

## Problem

The lab has no discrete GPU. Every Proxmox host is a mini PC with an
integrated Intel iGPU only:

- **6× Beelink S13** — Intel N100/N150 (Alder Lake-N, Gen12 Xe-LP, 24 EUs,
  Quick Sync: H.264/H.265/VP9 encode+decode, AV1 decode).
- **1× HP Slim S01-pF1xxx** (192.168.20.87) — iGPU class TBD, needs
  on-host `lspci | grep VGA` to confirm.

A Jellyfin-class media server with hardware transcoding needs GPU access
inside a Talos VM, scheduled by Kubernetes. Talos is immutable — kernel
modules ship as `siderolabs/extensions` system extensions baked into the
Talos image at factory.talos.dev.

The interesting question is whether to share one iGPU across multiple
Talos VMs (true SR-IOV) or hand a single iGPU exclusively to one node
and let Kubernetes handle "sharing" at the scheduler layer.

## Options considered

### 1. VFIO PCI passthrough (single VM, exclusive)

- **Works today.** Standard Proxmox flow.
- **Host changes:** `intel_iommu=on iommu=pt`, blacklist `i915`, bind GPU
  to `vfio-pci` via `/etc/modprobe.d`.
- **Talos changes:** add `siderolabs/i915-ucode` + `siderolabs/intel-ucode`
  system extensions to the image.
- **Terraform delta:** `hostpci` block on the `proxmox_virtual_environment_vm`
  resource (`bpg/proxmox` provider), `pcie = true`, `rombar = true`.
  Pinned provider version in `terraform/dev/talos-pve-v3.1.0/` must be
  verified to support these attributes.
- **K8s integration:** Intel GPU device plugin DaemonSet
  ([intel/intel-device-plugins-for-kubernetes](https://github.com/intel/intel-device-plugins-for-kubernetes))
  exposes the GPU as the `gpu.intel.com/i915` resource. `shared-dev-num`
  knob lets multiple pods on the GPU-bearing node share access.
- **Tradeoff:** defeats "shared across VMs" — only one Talos VM sees the
  GPU. Sharing happens at the K8s scheduler instead of the hypervisor.

### 2. Intel SR-IOV via `strongtz/i915-sriov-dkms`

- **Status on Alder Lake-N: poor.** The dkms project officially supports
  12th-gen desktop/mobile (ADL-P/ADL-S). ADL-N is "community reports
  mixed, often unstable." See
  [github.com/strongtz/i915-sriov-dkms#supported-platforms](https://github.com/strongtz/i915-sriov-dkms).
- **Host changes:** patched i915 module via dkms (Proxmox kernel 6.8+),
  `i915.enable_guc=3 i915.max_vfs=7`, IOMMU on. Out-of-tree, unsupported
  by Proxmox proper.
- **Talos changes:** same `i915-ucode` + `intel-ucode` extensions — the
  VF appears as a standard i915 device to the guest, no special driver.
- **Terraform delta:** one `hostpci` entry per VM referencing the VF BDF
  (e.g. `0000:00:02.1`).
- **K8s integration:** Intel device plugin works against VFs; each VM
  sees one `/dev/dri/renderD128`.
- **Tradeoff:** the only option that genuinely shares one iGPU across
  multiple VMs. Cost: dkms breaks on every Proxmox kernel bump, and
  ADL-N isn't a first-class target — high ongoing maintenance burden.

### 3. Intel GVT-g

- Dead end. Removed from i915 for Gen12+. ADL-N is unsupported. Skip.

### 4. Single-node passthrough on the HP Slim (variant of #1)

- Same mechanics as Option 1, but acknowledged as the pragmatic path:
  the HP Slim is outside the 6-node Beelink quorum, so losing it to GPU
  duty doesn't dent control-plane/worker capacity.
- Kubernetes handles "shared access" at the scheduling layer (1 GPU →
  N pods on that node) via the device plugin's `shared-dev-num`
  fractional allocation. Pin transcoding pods with nodeAffinity.

### 5. Other paths

- **LXC bind-mount of `/dev/dri`** — not applicable; Talos is a VM, not
  an LXC.
- **vGPU via Intel Flex / Data Center GPUs** — wrong hardware class.

## Recommendation

**Start with Option 4 — single-node passthrough on the HP Slim S01.**

Rationale:

- Jellyfin only needs one transcoding target. Kubernetes handles
  "sharing" at the scheduling layer (the Intel device plugin already
  supports fractional allocation via `shared-dev-num`).
- The HP Slim sits outside the Beelink quorum; dedicating it to GPU
  duty doesn't reduce control-plane/worker capacity.
- Avoids the dkms maintenance burden of SR-IOV entirely.

**Revisit Option 2 (SR-IOV) only if** a second GPU-bound workload
appears (Immich ML, Frigate) and pinning both to one node causes
contention. By then `i915-sriov-dkms` ADL-N support may have matured,
or Intel may have upstreamed SR-IOV (tracking:
[patchwork.freedesktop.org/project/intel-gfx/](https://patchwork.freedesktop.org/project/intel-gfx/)).

## Open questions / next research

1. **Confirm HP Slim iGPU generation** and Quick Sync codec matrix
   (`lspci | grep VGA` on the host). If it's also ADL-N or newer it's
   good; if it's older (Comet Lake UHD 610-class), still fine for Quick
   Sync but verify codec list against Jellyfin's needs.
2. **Verify `bpg/proxmox` provider version** pinned in
   `terraform/dev/talos-pve-v3.1.0/` supports `hostpci` with `pcie` /
   `mdev` attributes.
3. **Pick exact Talos extensions** from
   [factory.talos.dev](https://factory.talos.dev) — confirm whether both
   `siderolabs/i915-ucode` and `siderolabs/intel-ucode` are needed, or
   if `i915-ucode` bundles microcode already.
4. **Validate the Intel GPU device plugin DaemonSet** against the lab's
   Kyverno `add-default-securitycontext` policy — the plugin pod runs
   privileged, which will collide with the cluster-wide
   `runAsUser → 65534` mutation unless an explicit exception is added
   (see [[project_kyverno_default_securitycontext]]).
5. **Test extension rollout on one node first** before fleet-wide Talos
   image rebuild — extension changes mean a re-image, not a hot reload.

## Out of scope

- Application manifests for Jellyfin (or any media server).
- TrueNAS share/PVC layout for the media library.
- External exposure path (Tailscale vs. Cloudflare Tunnel) — see
  [[sso-authentik-decision]] for the in-flight tunnel decision.
- GPU-bound non-media workloads (Immich ML, Frigate) — listed only as
  future revisit triggers.
