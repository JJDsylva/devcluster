locals {
  controlplane_nodes = {
    for idx, ip in var.controlplane_ips :
    "talos-${var.cluster_name}-cp-${idx + 1}" => {
      ip    = ip
      vm_id = var.vm_id_start + idx
    }
  }

  # image download-by-url requires proxmox api tokens to be rejected (proxmox
  # security restriction, not fixable via acl) - so it's uploaded manually
  # once and referenced here instead of via proxmox_download_file.
  talos_image_id = "local:iso/talos-v1.13.8-nocloud-amd64.img"
}

resource "proxmox_virtual_environment_vm" "talos_node" {
  for_each = local.controlplane_nodes

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory
  }

  disk {
    datastore_id = "VMS"
    file_id      = local.talos_image_id
    interface    = "scsi0"
    size         = var.vm_disk_size
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true # talos doesn't run qemu-guest-agent by default
  }

  initialization {
    datastore_id = "VMS"

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.network_gateway
      }
    }
  }

  started = true
}
