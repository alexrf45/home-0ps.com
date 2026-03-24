# cilium.tf - Cilium CNI rendered via helm template, applied via kubectl
# data.helm_template renders the chart at plan time without cluster credentials.
# The null_resource applies the manifests after k3s is ready (module.hetzner completes).

data "helm_template" "cilium" {
  name             = "cilium"
  namespace        = var.cilium_config.namespace
  create_namespace = true
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  version          = var.cilium_config.cilium_version

  values = [
    yamlencode({
      resources = {
        limits = {
          cpu    = "1000m"
          memory = "250Mi"
        }
        requests = {
          cpu    = "100m"
          memory = "100Mi"
        }
      }

      ipam = {
        mode = "kubernetes"
      }

      kubeProxyReplacement = true
      enableIPv6Masquerade = false
      dnsPolicy            = "ClusterFirst"

      encryption = {
        enabled        = true
        nodeEncryption = true
        type           = "wireguard"
        wireguard = {
          persistentKeepalive = "0s"
        }
      }

      # L2 announcements disabled — Hetzner LB handles external ingress
      l2announcements = {
        enabled = false
      }

      # Tolerate the CCM uninitialized taint so Cilium can start on new nodes
      tolerations = [
        {
          key      = "node.cloudprovider.kubernetes.io/uninitialized"
          operator = "Exists"
          effect   = "NoSchedule"
        },
        {
          key      = "node.kubernetes.io/not-ready"
          operator = "Exists"
          effect   = "NoSchedule"
        },
      ]

      securityContext = {
        capabilities = {
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
          ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        }
      }

      hubble = {
        enabled           = var.cilium_config.hubble_enabled
        enableOpenMetrics = false
        metrics = {
          enabled = ["dns:query", "drop", "tcp", "flow", "port-distribution", "icmp", "http"]
        }
        relay = {
          enabled     = var.cilium_config.relay_enabled
          rollOutPods = var.cilium_config.relay_pods_rollout
        }
        ui = {
          enabled = var.cilium_config.hubble_ui_enabled
        }
      }

      # Talos manages cgroups itself — disable automount
      cgroup = {
        autoMount = {
          enabled = false
        }
        hostRoot = "/sys/fs/cgroup"
      }

      # Talos uses a local kube-proxy on port 7445
      k8sServiceHost = "127.0.0.1"
      k8sServicePort = "7445"

      # Ingress controller disabled — using Gateway API only
      ingressController = {
        enabled = false
      }

      gatewayAPI = {
        enabled = var.cilium_config.gateway_api_enabled
        gatewayClass = {
          create = "auto"
        }
      }

      redact = {
        enabled = true
        http = {
          urlQuery = true
          userInfo = true
        }
      }

      externalIPs = {
        enabled = true
      }

      k8sClientRateLimit = {
        qps   = 30
        burst = 50
      }
    })
  ]
}

resource "local_file" "cilium_manifest" {
  content  = data.helm_template.cilium.manifest
  filename = "${path.module}/.cilium-manifest.yaml"
}

resource "null_resource" "cilium_installed" {
  depends_on = [module.hetzner, local_file.cilium_manifest, local_sensitive_file.kubeconfig]

  triggers = {
    manifest_hash = sha256(data.helm_template.cilium.manifest)
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = "${path.module}/.kubeconfig"
      NAMESPACE  = var.cilium_config.namespace
      MANIFEST   = "${path.module}/.cilium-manifest.yaml"
    }
    command = <<-EOT
      kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f "$MANIFEST"
      kubectl rollout status daemonset/cilium -n "$NAMESPACE" --timeout=5m
      kubectl rollout status deployment/cilium-operator -n "$NAMESPACE" --timeout=3m
      kubectl rollout status deployment/coredns -n kube-system --timeout=3m
    EOT
  }
}
