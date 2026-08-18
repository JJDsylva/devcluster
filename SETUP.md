# codeomelet.dev homelab cluster - project log

Living document, updated as we go. Repo: `github.com/JJDsylva/devcluster`.
Repo layout: `terraform/` (cluster bootstrap, own git history of secrets
kept out via `.gitignore`) and `clusters/dev/` (GitOps manifests, synced by
ArgoCD). ArgoCD's root app watches `clusters/dev/apps` specifically (not
`clusters/dev` itself - see bug #6 below for why that distinction matters).

**Status as of last update: cluster is up, Cloudflare Tunnel is live,
Authentik/Postgres/Traefik/cloudflared are all Running. Only remaining step
is the one-time Authentik login + forward-auth provider setup below.**

---

## Architecture overview (current)

- **Infra**: 3x Proxmox VM control-plane nodes, Talos Linux v1.13.8
- **Cluster**: Terraform-managed bootstrap (`terraform/talos.tf`, `vm.tf`,
  `providers.tf`, `variables.tf`), cluster name `dev`, VIP `10.10.10.50`,
  nodes `10.10.10.51/.52/.53`
- **CNI**: Cilium, replaces kube-proxy (`kubeProxyReplacement=true`),
  `ipam.mode=kubernetes`. Talos config patches:
  `cluster.network.cni.name = none`, `cluster.proxy.disabled = true`
- **Storage**: `local-path-provisioner` (Rancher), set as default
  StorageClass, patched for Talos's read-only rootfs (see bug #6)
- **GitOps**: ArgoCD deployed via Terraform (`terraform/argocd.tf`) as the
  one Terraform-managed piece; it's the root app-of-apps pointed at
  `https://github.com/JJDsylva/devcluster.git`, branch `main`, path
  `clusters/dev/apps`. Everything else lives as manifests under
  `clusters/dev/` in that repo, synced by ArgoCD - not in Terraform.
- **Domain**: `codeomelet.dev` (Cloudflare DNS). Per-service subdomains
  under one root.
  - `argocd.codeomelet.dev`
  - `auth.codeomelet.dev`
  - (add more here as apps are added)
- **Ingress path**: Cloudflare Tunnel -> Traefik (in-cluster,
  `traefik.traefik.svc.cluster.local:80`) -> app services. Cilium stays
  CNI-only. Tunnel ID `1e1d15b7-779d-4333-99ae-d1ce73edf821`
  (`k8s-codeomelet`).
- **Auth**: Authentik gates apps via forward-auth, **domain-level mode**
  (not single-application) - one login persists across every
  `*.codeomelet.dev` subdomain via a cookie scoped to `.codeomelet.dev`,
  and there's only one Provider to configure in Authentik total, not one
  per app. Wired via a single shared Traefik `Middleware` referenced from
  each app's Ingress by annotation. Authentik's own Ingress deliberately
  has no forward-auth annotation on it (would create a redirect loop).
- **ArgoCD backend**: `argocd-server` set to `server.insecure=true` (via
  `configs.params."server\.insecure"` Helm value in `argocd.tf`) - TLS is
  already terminated upstream at Cloudflare + Traefik, so the backend
  serves plain HTTP and Ingress doesn't need backend-TLS annotations.
- **Secrets**: Sealed Secrets (`https://bitnami.github.io/sealed-secrets`
  chart, `kube-system` namespace). Real secret values never touch git -
  sealed locally with `kubeseal` against the cluster's public cert, only
  ciphertext committed. Two secrets sealed so far: tunnel credentials
  (`clusters/dev/cloudflared/cloudflared-tunnel-credentials.sealed.yaml`)
  and Authentik's key/DB password
  (`clusters/dev/ingress/authentik-creds.sealed.yaml`).

---

## Decisions made along the way

- **Hostname layout**: per-service subdomains under `codeomelet.dev`, not a
  single `lab.codeomelet.dev` with paths, not a separate domain.
- **Auth model**: gate everything behind Authentik forward-auth via the
  tunnel, domain-level mode specifically (see below) rather than
  Cloudflare Access or single-application-per-provider mode.
- **Secrets handling**: Sealed Secrets set up now, not deferred.
- **Tunnel management style**: locally-created tunnel (`cloudflared tunnel
  create`), ingress rules declared in a git-tracked ConfigMap - not a
  dashboard-managed tunnel with hostnames configured out-of-band.
- **Ingress controller: Traefik, not ingress-nginx.** Originally planned
  ingress-nginx (`kubernetes/ingress-nginx`), but that project was
  **officially retired in March 2026** - no more releases, bugfixes, or
  security patches, ever. Traefik was picked over Cilium's own Gateway
  API/Envoy because Authentik's forward-auth integration is officially
  documented for Traefik (and nginx) but not for Cilium's Envoy.
- **Domain-level vs single-application forward auth**: domain-level needs
  exactly one Provider for the whole `codeomelet.dev` domain, every app
  just references the same shared Middleware - a much better fit than
  single-application mode given the shared-root-domain hostname layout.
- **`argocd-server` insecure mode**: rather than fight Traefik
  backend-TLS/ServersTransport config, argocd-server just serves plain
  HTTP directly (standard when TLS is already terminated upstream).
- **Repo layout**: `terraform/` and `clusters/dev/` split into one
  monorepo (`devcluster`), not two separate repos - `terraform/` holds
  state/secrets that are gitignored, `clusters/dev/` is what ArgoCD syncs.
- **local-path-provisioner over Longhorn/Proxmox CSI**: simplest option
  for a single-node-class (all 3 nodes are control-plane, schedulable)
  homelab cluster - no iSCSI/extra host packages needed, works with
  Talos's writable `/var` once the extraMounts gotcha (bug #6) is handled.

---

## Bugs hit and fixed

1. **`rpc error: ... produced zero addresses`** on
   `talos_machine_configuration_apply`. Cause: `node` was fed
   `each.value.ip` from `local.controlplane_nodes` in `vm.tf`, which keeps
   the `/24` CIDR suffix (needed for Proxmox's `ip_config`), but the Talos
   gRPC client needs a bare IP. Fix: `node = split("/", each.value.ip)[0]`.

2. **`error decoding document v1alpha1/ResolverConfig ... unknown keys ...
   hostDNS`**. Cause: `providers.tf` was pinned to `siderolabs/talos`
   `0.12.0-alpha.5`, an alpha whose bundled Talos SDK targets `v1.14.0-
   alpha.1` - schema skew against the actual `v1.13.8` node image. Fix:
   pinned to stable `0.11.0`.

3. **`Kubernetes cluster unreachable: dial tcp :6443: connection refused`**
   (and later `no route to host` on a full VM rebuild) on
   `helm_release.cilium`. Cause: the Talos provider's config-apply/
   bootstrap resources return as soon as the RPC is accepted, not once the
   node has actually finished rebooting/bootstrapping/electing the VIP -
   on a cold VM boot that can take minutes. Fix: `time_sleep.wait_for_api`
   (60s) between `talos_cluster_kubeconfig` and anything hitting `:6443`.
   Tried replacing this with an active-poll `null_resource` for
   robustness, but a plain `terraform destroy` + `apply` fixed the actual
   failure faster than debugging the poll approach - reverted back to
   `time_sleep`, decided not worth the complexity for now. (Also
   separately: a copy-paste at some point left `time_sleep.wait_for_api`
   declared *twice* in `talos.tf`, causing a "Duplicate resource" error -
   just deleted the redundant block, no functional cause.)

4. **Cilium agent pods `Init:CrashLoopBackOff`**, error `unable to apply
   caps: can't apply capabilities: operation not permitted` on
   `clean-cilium-state`. Cause: Talos permanently blocks `CAP_SYS_MODULE`/
   `CAP_SYS_BOOT` for every process, even privileged ones - Cilium's
   default Helm chart requests `SYS_MODULE`. Fix (`cilium.tf`): narrowed
   `securityContext.capabilities.ciliumAgent`/`.cleanCiliumState` to drop
   `SYS_MODULE`, set `cgroup.autoMount.enabled=false`,
   `cgroup.hostRoot=/sys/fs/cgroup`.

5. **ArgoCD root app `Synced`/`Healthy` but zero child Applications
   created.** Cause: root's `path` was `clusters/dev`, but all the
   `Application` manifests live one level deeper in `clusters/dev/apps/` -
   ArgoCD's directory source only looks at files directly in the given
   path unless `recurse: true` is set. Fix: pointed root's `path` at
   `${var.github_repo_path}/apps` specifically instead of adding recurse
   (recursing would've also tried to directly apply the raw manifests
   under `cloudflared/`/`ingress/` through root, conflicting with those
   folders' own wrapper Applications).

6. **`authentik-postgresql-0` stuck `Pending` forever, PVC never bound.**
   Root cause had two layers:
   - No default StorageClass existed at all on this bare-metal Talos
     cluster. Fixed by deploying `local-path-provisioner` (see Kustomize
     patches in `clusters/dev/storage/`), patched per Talos's own docs to
     use `/var/mnt/local-path-provisioner` instead of the chart's default
     `/opt/local-path-provisioner`, since Talos's rootfs is read-only
     outside `/var`.
   - Even after that, the provisioner's helper pods sat in
     `ContainerCreating` forever (`create process timeout after 120
     seconds`). Same root cause as bug #4's Cilium mount issue: Talos's
     kubelet runs in its own sandboxed mount namespace, and paths under
     `/var/mnt/*` aren't exposed into that namespace by default, even
     though `/var` itself is writable on disk. Fixed with the same
     `machine.kubelet.extraMounts` pattern used for Cilium's
     `/var/lib/cilium` mount, this time for
     `/var/mnt/local-path-provisioner`, in `terraform/talos.tf`.

**Status: all fixed, full stack confirmed healthy** - nodes Ready, Cilium/
Traefik/cloudflared/sealed-secrets/local-path-provisioner all Running,
Authentik server+worker+postgres all Running.

---

## Cloudflare Tunnel + Authentik rollout

### What's live right now

- Tunnel `k8s-codeomelet` (`1e1d15b7-779d-4333-99ae-d1ce73edf821`) created,
  DNS CNAMEs routed for `argocd.codeomelet.dev` and `auth.codeomelet.dev`
- Both sealed secrets committed and applied - `cloudflared` and
  `authentik` ArgoCD Applications are healthy
- `local-path-provisioner` deployed and set as default StorageClass
- All ArgoCD Applications synced: `root`, `sealed-secrets`, `traefik`,
  `cloudflared`, `authentik`, `ingress`, `local-path-provisioner`

### Still TODO

- [ ] **The one manual step left**: log into `https://auth.codeomelet.dev`
      as `akadmin` (bootstrap password is in the chart-generated
      `authentik-bootstrap-password`/`authentik-bootstrap-token` secret in
      the `authentik` namespace - `kubectl get secret -n authentik` to
      find the exact name). One-time setup:
      **Applications > Providers > Create > Proxy Provider > Forward auth
      (domain level)**, external host `https://auth.codeomelet.dev`,
      cookie domain `codeomelet.dev` -> bind to an Application -> assign
      to the embedded outpost.
- [ ] Verify end-to-end: `https://argocd.codeomelet.dev` should redirect to
      Authentik login, then land back on ArgoCD after auth
- [ ] Cosmetic, not blocking: Traefik's Service is `type: LoadBalancer`
      sitting `<pending>` forever instead of `ClusterIP` as intended - the
      `service.type`/`ports.web.port` values we set in `apps/traefik.yaml`
      aren't the right key path for chart 41.2.0 (values ARE reaching
      Helm, confirmed via `kubectl get application traefik -o yaml` -
      just wrong keys). `cloudflared` still reaches it fine via ClusterIP
      regardless of `type`, so this doesn't block anything - fix whenever:
      `helm show values traefik/traefik --version 41.2.0 | grep -B2 -A5
      "^service:"` to find the real key.
- [ ] cloudflared client itself flagged as outdated (`2026.7.3` ->
      `2026.8.2` available) - not urgent, upgrade whenever.

---

## Adding a new app behind auth

Because auth is domain-level, adding a new app needs **no new Authentik
Provider** - just:

1. Add a Service for the app (or it comes with one via its own chart).
2. Add a hostname line to `clusters/dev/cloudflared/configmap.yaml`:
   `- hostname: <app>.codeomelet.dev` -> `service: http://traefik.traefik.
   svc.cluster.local:80`
3. `cloudflared tunnel route dns k8s-codeomelet <app>.codeomelet.dev`
4. Add an Ingress in `clusters/dev/ingress/` with:
   `traefik.ingress.kubernetes.io/router.middlewares:
   authentik-authentik-forwardauth@kubernetescrd`
   (same middleware every time - that's the point of domain-level mode)
5. If the app needs persistent storage, it'll pick up `local-path` as the
   default StorageClass automatically - no extra config needed unless it
   wants a non-default class.

No tunnel recreation, no new Authentik Provider, no Terraform changes for
steps 1-4. Step 5 only needs a Terraform change if you're adding an
entirely new hostPath-style dependency the way `local-path-provisioner`
needed `extraMounts` - normal PVCs on the existing StorageClass need
nothing extra.

---

## Future: genericizing this into a template repo (not started yet)

Goal: fork-and-go for someone else - edit **one** config file, run a render
step, get a working set of manifests for their own domain/cluster.

Planned approach: **Jinja2 templates + a single `config.yaml`**, rendered
by a small script, checked in as `Makefile` target `make render`.

Rough shape (to build once the base above is proven working - it now is,
so this is next up once you're ready):

```
config.example.yaml       <- copy to config.yaml, fill in your values
templates/
  clusters/dev/apps/authentik.yaml.j2
  clusters/dev/apps/cloudflared.yaml.j2
  clusters/dev/cloudflared/configmap.yaml.j2
  clusters/dev/ingress/*.yaml.j2
  clusters/dev/storage/kustomization.yaml.j2
  ...
render.py                 <- loads config.yaml, renders templates/**/*.j2
                              into their real paths (strips .j2 suffix)
Makefile                  <- `make render` runs render.py
```

`config.yaml` would hold everything currently hardcoded across these files:
domain, per-app subdomain list, cluster name, controlplane IPs/VIP, github
repo url/branch, chart version pins, Cilium version, whether a given app
gets gated behind auth, etc.

Open question for when we get there: fold the Terraform side
(`variables.tf`/`terraform.tfvars`) into the same `config.yaml`, or keep
Terraform on its own `tfvars` (it already has its own templating via
variables) and use Jinja only for the GitOps-repo YAML that doesn't have
Terraform's engine available. Leaning toward the latter.
