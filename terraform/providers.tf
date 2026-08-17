terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.111.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url   # e.g. https://192.168.1.10:8006
  api_token = var.proxmox_api_token # user@pve!tokenid=uuid
  insecure  = true                  # skip TLS verify for self-signed certs

  # required for importing the talos .img as a disk (qm importdisk) - the
  # proxmox API has no endpoint for that, so the provider shells out over SSH.
  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}

# kubernetes/helm providers read credentials straight out of the talos-generated
# kubeconfig, so nothing needs to be exported to disk or run twice.
locals {
  kubeconfig_parsed = yamldecode(talos_cluster_kubeconfig.this.kubeconfig_raw)
  kube_cluster       = local.kubeconfig_parsed.clusters[0].cluster
  kube_user          = local.kubeconfig_parsed.users[0].user
}

provider "kubernetes" {
  host                   = local.kube_cluster.server
  cluster_ca_certificate = base64decode(local.kube_cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kube_user["client-certificate-data"])
  client_key             = base64decode(local.kube_user["client-key-data"])
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_cluster.server
    cluster_ca_certificate = base64decode(local.kube_cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kube_user["client-certificate-data"])
    client_key             = base64decode(local.kube_user["client-key-data"])
  }
}
