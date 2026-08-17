output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "controlplane_vip" {
  value = var.controlplane_vip
}

output "argocd_initial_admin_password" {
  value     = data.kubernetes_secret_v1.argocd_admin.data["password"]
  sensitive = true
}
