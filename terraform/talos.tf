resource "talos_machine_secrets" "this" {}

locals {
  node_ips     = [for ip in var.controlplane_ips : split("/", ip)[0]]
  first_node   = local.node_ips[0]
  cluster_name = var.cluster_name
}

data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = local.node_ips
  endpoints            = [var.controlplane_vip]
}

# one shared controlplane config - applied to all 3 nodes.
# taint removed (allowSchedulingOnControlPlanes) so they run workloads too.
# CNI + kube-proxy disabled here because Cilium replaces both (installed via helm below).
# kubelet.extraMounts is required so Cilium's init container can mount /sys/fs/bpf -
# without it, the cilium agent pods fail with Init:RunContainerError / Init:CrashLoopBackOff.
data "talos_machine_configuration" "controlplane" {
  cluster_name     = local.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = "https://${var.controlplane_vip}:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
      }
      machine = {
        kubelet = {
          extraMounts = [
            {
              destination = "/var/lib/cilium"
              type        = "bind"
              source      = "/var/lib/cilium"
              options     = ["bind", "rshared", "rw"]
            },
            {
              # local-path-provisioner's helper pods hostPath-mount this to
              # create each PV's directory - without this, Talos's sandboxed
              # kubelet mount namespace doesn't expose /var/mnt/* to pods,
              # and the helper pod sits in ContainerCreating forever.
              destination = "/var/mnt/local-path-provisioner"
              type        = "bind"
              source      = "/var/mnt/local-path-provisioner"
              options     = ["bind", "rshared", "rw"]
            }
          ]
        }
        network = {
          interfaces = [
            {
              interface = var.network_interface
              dhcp      = false
              vip = {
                ip = var.controlplane_vip
              }
            }
          ]
        }
      }
    })
  ]
}

resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.controlplane_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                         = split("/", each.value.ip)[0]

  depends_on = [proxmox_virtual_environment_vm.talos_node]
}

# bootstrap etcd once, from any single node
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                  = local.first_node

  depends_on = [talos_machine_configuration_apply.controlplane]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                  = local.first_node
  endpoint              = var.controlplane_vip

  depends_on = [talos_machine_bootstrap.this]
}

# kubeconfig only proves the Talos API handed over a config file - it says
# nothing about whether kube-apiserver on the VIP is actually accepting
# connections yet (etcd quorum + static pod startup take a bit after
# bootstrap). Give it time before anything tries to talk to :6443.
resource "time_sleep" "wait_for_api" {
  depends_on      = [talos_cluster_kubeconfig.this]
  create_duration = "60s"
}
