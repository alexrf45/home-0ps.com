#cloud-config
package_update: true
packages:
  - curl

runcmd:
  - |
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_CHANNEL="${k3s_channel}" \
      K3S_TOKEN="${k3s_token}" \
      K3S_URL="https://${cp_private_ip}:6443" \
      sh -s - agent \
        --kubelet-arg=cloud-provider=external
