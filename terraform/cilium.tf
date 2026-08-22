resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  # kube-proxy replacement: cluster.network.cni.name = "none" and
  # cluster.proxy.disabled = true were set in the talos config patch,
  # so Cilium needs to talk to the API server directly via the VIP.
  #
  # Talos-specific overrides (per Talos's own Cilium install docs):
  # - Talos permanently blocks CAP_SYS_MODULE/CAP_SYS_BOOT for every process,
  #   including privileged pods. Cilium's default capability set includes
  #   SYS_MODULE, so the clean-cilium-state init container crash-loops with
  #   "unable to apply caps: operation not permitted" unless we narrow it.
  # - Talos doesn't auto-mount cgroupv2 the way Cilium's chart expects, so
  #   cgroup.autoMount must be disabled and hostRoot pointed at Talos's path.
  set = [
    {
      name  = "kubeProxyReplacement"
      value = "true"
    },
    {
      name  = "hubble.relay.enabled"
      value = "true"
    },
    {
      name  = "hubble.ui.enabled"
      value = "true"
    },
    {
      name  = "k8sServiceHost"
      value = var.controlplane_vip
    },
    {
      name  = "k8sServicePort"
      value = "6443"
    },
    {
      name  = "ipam.mode"
      value = "kubernetes"
    },
    {
      name  = "cgroup.autoMount.enabled"
      value = "false"
    },
    {
      name  = "cgroup.hostRoot"
      value = "/sys/fs/cgroup"
    },
    {
      name  = "securityContext.capabilities.ciliumAgent"
      value = "{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
    },
    {
      name  = "securityContext.capabilities.cleanCiliumState"
      value = "{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
    },
  ]

  depends_on = [time_sleep.wait_for_api]
}
