variable "proxmox_api_url" {}
variable "proxmox_api_token" {
  sensitive = true
}
variable "proxmox_node" {
  default = "pve" # your proxmox node name
}
variable "proxmox_ssh_username" {
  description = "SSH user on the proxmox host - needed for disk-image import operations the API can't do"
  default     = "root"
}

# --- cluster identity ---
variable "cluster_name" {
  default = "dev"
}

# --- control plane nodes (3x, untainted so they schedule workloads too) ---
variable "vm_id_start" {
  default = 7000 # nodes get vm_id_start, +1, +2
}
variable "controlplane_ips" {
  description = "One /CIDR per control plane node"
  type        = list(string)
  default = [
    "10.10.10.51/24",
    "10.10.10.52/24",
    "10.10.10.53/24",
  ]
}
variable "controlplane_vip" {
  description = "Shared virtual IP that floats across control plane nodes - use this as the cluster endpoint"
  default     = "10.10.10.50"
}
variable "network_gateway" {
  default = "10.10.10.1"
}
variable "network_interface" {
  description = "Interface name inside the Talos VM that the VIP binds to - check with talosctl get links if unsure"
  default     = "eth0"
}

variable "vm_cores" {
  default = 4
}
variable "vm_memory" {
  default = 16384
}
variable "vm_disk_size" {
  default = 60
}

# --- cilium ---
variable "cilium_version" {
  default = "1.20.0"
}

# --- argocd ---
variable "argocd_chart_version" {
  default = "10.3.1"
}
variable "github_repo_url" {
  description = "Repo ArgoCD's root app watches - push manifests here to deploy"
  default     = "https://github.com/JJDsylva/devcluster"
}
variable "github_repo_branch" {
  default = "main"
}
variable "github_repo_path" {
  description = "Path within the repo for this cluster's manifests (e.g. clusters/dev)"
  default     = "clusters/dev"
}
