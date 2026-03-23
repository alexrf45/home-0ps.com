#cloud-config
package_update: true
packages:
  - curl

runcmd:
  - |
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_CHANNEL="${k3s_channel}" \
      K3S_TOKEN="${k3s_token}" \
      sh -s - server \
        --flannel-backend=none \
        --disable-kube-proxy \
        --disable-network-policy \
        --disable traefik \
        --disable servicelb \
        --cluster-cidr="${pod_cidr}" \
        --service-cidr="${service_cidr}" \
        --tls-san="${cp_public_ip}" \
        --tls-san="${cp_private_ip}" \
        --node-ip="${cp_private_ip}" \
        --kubelet-arg=cloud-provider=external
