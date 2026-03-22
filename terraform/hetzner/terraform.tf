# terraform.tf - Root module for Hetzner cluster
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.60.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "3.2.1"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "1.7.6"
    }
  }

  backend "s3" {}
}
