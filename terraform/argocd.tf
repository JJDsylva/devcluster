resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  # TLS is terminated upstream (Cloudflare Tunnel -> Traefik), so argocd-server
  # doesn't need to also serve its own self-signed cert - this lets the
  # Ingress talk to it over plain HTTP without backend-TLS annotations/
  # ServersTransport config.
  set = [
    {
      name  = "configs.params.server\\.insecure"
      value = "true"
    },
  ]

  depends_on = [helm_release.cilium]
}

# app-of-apps: this is the ONLY thing terraform manages inside argocd.
# every other app (cloudflared, whatever else) lives as a manifest in the
# github repo below - push to github and argocd syncs it, no terraform needed.
#
# applied via `kubectl apply` (local-exec) instead of a kubernetes-aware
# terraform resource: both kubernetes_manifest and the kubectl provider try to
# validate/discover schema against a live API server before the cluster
# exists (plan time or provider-configure time), which fails on a
# from-scratch cluster. Shelling out sidesteps that entirely - it only
# touches the cluster once it's real, after helm_release.argocd is done.
# Requires `kubectl` to be installed on the machine running terraform.

resource "local_sensitive_file" "kubeconfig" {
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename = "${path.module}/.kubeconfig-${var.cluster_name}"
}

resource "local_file" "argocd_root_app" {
  filename = "${path.module}/.argocd-root-app-${var.cluster_name}.yaml"
  content = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.github_repo_url
        targetRevision = var.github_repo_branch
        path           = "${var.github_repo_path}/apps"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  })
}

resource "null_resource" "argocd_root_app_apply" {
  triggers = {
    manifest_hash = sha256(local_file.argocd_root_app.content)
  }

  provisioner "local-exec" {
    command = "kubectl --kubeconfig ${local_sensitive_file.kubeconfig.filename} apply -f ${local_file.argocd_root_app.filename}"
  }

  depends_on = [
    helm_release.argocd,
    local_sensitive_file.kubeconfig,
    local_file.argocd_root_app,
  ]
}

data "kubernetes_secret_v1" "argocd_admin" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }

  depends_on = [helm_release.argocd]
}
