resource "talos_machine_secrets" "this" {
  talos_version = var.talos.version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes = concat(
    [for k, v in var.controlplane_nodes : hcloud_server.controlplane[k].ipv4_address],
    [for k, v in var.worker_nodes : hcloud_server.worker[k].ipv4_address],
  )
  endpoints = [for k, v in var.controlplane_nodes : hcloud_server.controlplane[k].ipv4_address]
}


data "talos_machine_configuration" "controlplane" {
  for_each         = var.controlplane_nodes
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${local.cluster_endpoint}:6443"
  talos_version    = var.talos.version
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    <<-EOT
    version: v1alpha1
    machine:
      sysctls:
        vm.nr_hugepages: "1024"
      files:
        - path: /etc/cri/conf.d/20-customization.part
          op: create
          content: |
            [plugins."io.containerd.cri.v1.images"]
              discard_unpacked_layers = false
            [plugins."io.containerd.cri.v1.runtime"]
              device_ownership_from_security_context = true
      time:
        servers:
          - time.cloudflare.com
      kubelet:
        extraArgs:
          rotate-server-certificates: "true"
          cloud-provider: external
        clusterDNS:
          - ${local.coredns_ip}
        nodeIP:
          validSubnets:
            - 10.0.1.0/24
      install:
        disk: /dev/sda
        image: ${data.talos_image_factory_urls.this.urls.installer}
        wipe: true
        extraKernelArgs:
          - panic=10
          - disable_ipv6=1
      network:
        nameservers:
          - 1.1.1.1
          - 8.8.8.8
    cluster:
      apiServer:
        auditPolicy:
          apiVersion: audit.k8s.io/v1
          kind: Policy
          rules:
            - level: Metadata
        admissionControl:
          - name: PodSecurity
            configuration:
              apiVersion: pod-security.admission.config.k8s.io/v1beta1
              kind: PodSecurityConfiguration
              exemptions:
                namespaces:
                  - networking
                  - storage
                  - kube-system
      network:
        cni:
          name: none
        podSubnets:
          - ${local.pod_subnet}
        serviceSubnets:
          - ${local.service_subnet}
      proxy:
        disabled: true
      extraManifests:
        - https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/main/deploy/standalone-install.yaml
        - https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        - https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
      inlineManifests:
        - name: namespace-flux
          contents: |
            apiVersion: v1
            kind: Namespace
            metadata:
              name: flux-system
        - name: namespace-networking
          contents: |
            apiVersion: v1
            kind: Namespace
            metadata:
              name: networking
              labels:
                pod-security.kubernetes.io/enforce: "privileged"
                app: "networking"
        - name: namespace-storage
          contents: |
            apiVersion: v1
            kind: Namespace
            metadata:
              name: storage
              labels:
                pod-security.kubernetes.io/enforce: "privileged"
                app: "storage"
    EOT
    ,
  ]
}


data "talos_machine_configuration" "worker" {
  for_each         = var.worker_nodes
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${local.cluster_endpoint}:6443"
  talos_version    = var.talos.version
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    <<-EOT
    version: v1alpha1
    cluster:
      network:
        podSubnets:
          - ${local.pod_subnet}
        serviceSubnets:
          - ${local.service_subnet}
    machine:
      sysctls:
        vm.nr_hugepages: "1024"
      files:
        - path: /etc/cri/conf.d/20-customization.part
          op: create
          content: |
            [plugins."io.containerd.cri.v1.images"]
              discard_unpacked_layers = false
            [plugins."io.containerd.cri.v1.runtime"]
              device_ownership_from_security_context = true
      time:
        servers:
          - time.cloudflare.com
      kubelet:
        extraArgs:
          rotate-server-certificates: "true"
          cloud-provider: external
        clusterDNS:
          - ${local.coredns_ip}
        nodeIP:
          validSubnets:
            - 10.0.1.0/24
      install:
        disk: /dev/sda
        image: ${data.talos_image_factory_urls.this.urls.installer}
        wipe: true
        extraKernelArgs:
          - panic=10
          - disable_ipv6=1
      network:
        nameservers:
          - 1.1.1.1
          - 8.8.8.8
    EOT
  ]
}


resource "talos_machine_configuration_apply" "controlplane" {
  depends_on = [
    hcloud_server.controlplane,
    hcloud_server_network.controlplane,
    data.talos_machine_configuration.controlplane,
  ]
  apply_mode = "auto"
  for_each   = var.controlplane_nodes
  node       = hcloud_server.controlplane[each.key].ipv4_address
  endpoint   = hcloud_server.controlplane[each.key].ipv4_address

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[each.key].machine_configuration

  config_patches = [
    <<-EOT
    ---
    apiVersion: v1alpha1
    kind: HostnameConfig
    auto: off
    hostname: ${var.env}-${var.cluster_name}-cp-${random_id.this[each.key].hex}
    ---
    version: v1alpha1
    cluster:
      allowSchedulingOnControlPlanes: true
    EOT
  ]

  timeouts = {
    create = "5m"
  }
}

resource "talos_machine_configuration_apply" "worker" {
  depends_on = [
    hcloud_server.worker,
    hcloud_server_network.worker,
    data.talos_machine_configuration.worker,
    talos_machine_configuration_apply.controlplane,
  ]
  apply_mode = "auto"
  for_each   = var.worker_nodes
  node       = hcloud_server.worker[each.key].ipv4_address
  endpoint   = hcloud_server.worker[each.key].ipv4_address

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[each.key].machine_configuration
  config_patches = [
    <<-EOT
    ---
    apiVersion: v1alpha1
    kind: HostnameConfig
    auto: off
    hostname: ${var.env}-${var.cluster_name}-node-${random_id.this[each.key].hex}
    EOT
  ]
  timeouts = {
    create = "5m"
  }
}


resource "time_sleep" "wait_until_apply" {
  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
  ]
  create_duration = "30s"
}

resource "talos_machine_bootstrap" "this" {
  count = var.bootstrap_cluster ? 1 : 0
  depends_on = [
    time_sleep.wait_until_apply,
  ]
  node                 = hcloud_server.controlplane[local.first_cp_key].ipv4_address
  endpoint             = hcloud_server.controlplane[local.first_cp_key].ipv4_address
  client_configuration = talos_machine_secrets.this.client_configuration
  timeouts = {
    create = "5m"
  }
}

resource "time_sleep" "wait_until_bootstrap" {
  depends_on      = [talos_machine_bootstrap.this]
  create_duration = "30s"
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [time_sleep.wait_until_bootstrap]
  node                 = hcloud_server.controlplane[local.first_cp_key].ipv4_address
  endpoint             = hcloud_server.controlplane[local.first_cp_key].ipv4_address
  client_configuration = talos_machine_secrets.this.client_configuration
  timeouts = {
    read   = "1m"
    create = "5m"
  }
}
