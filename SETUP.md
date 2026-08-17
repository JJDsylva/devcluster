# codeomelet.dev homelab cluster - project log

Living document, updated as we go. Repo: `github.com/JJDsylva/devcluster`.
ArgoCD's root app watches `clusters/dev` in this repo (Terraform variable
`github_repo_path`, left on default) - everything under
`clusters/dev/` in this repo is what gets deployed.

---

## Architecture overview (current)

- **Infra**: 3x Proxmox VM control-plane nodes, Talos Linux v1.13.8
- **Cluster**: Terraform-managed bootstrap (talos.tf, vm.tf, providers.tf,
  variables.tf), cluster name `dev`, VIP `10.10.10.50`, nodes
  `10.10.10.51/.52/.53`
- **CNI**: Cilium, replaces kube-proxy (`kubeProxyReplacement=true`),
  `ipam.mode=kubernetes`. Talos config patches:
  `cluster.network.cni.name = none`, `cluster.proxy.disabled = true`
- **GitOps**: ArgoCD deployed via Terraform (`argocd.tf`) as the one
  Terraform-managed piece; it's the root app-of-apps pointed at
  `https://github.com/JJDsylva/devcluster.git`, branch `main`, path
  `clusters/dev`. Everything else lives as manifests under
  `clusters/dev/` in that repo, synced by ArgoCD - not in Terraform.
- **Domain**: `codeomelet.dev` (Cloudflare DNS). Per-service subdomains
  under one root.
  - `argocd.codeomelet.dev`
  - `auth.codeomelet.dev`
  - (add more here as apps are added)
- **Ingress path**: Cloudflare Tunnel -> Traefik (in-cluster, ClusterIP) ->
  app services. Cilium stays CNI-only.
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
- **Secrets**: Sealed Secrets (bitnami-labs/bitnami controller, chart repo
  moved to `https://bitnami.github.io/sealed-secrets`). Real secret values
  never touch git - sealed locally with `kubeseal` against the cluster's
  public cert, only ciphertext committed.

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
  **officially retired in March 2026** (announced Nov 2025 at KubeCon NA by
  the Kubernetes Steering + Security Response Committees) - no more
  releases, bugfixes, or security patches, ever. Building fresh
  infrastructure on it today would mean starting on dead, unpatched
  software. Traefik was picked over Cilium's own Gateway API/Envoy because
  Authentik's forward-auth integration is officially documented for
  Traefik (and nginx) but not for Cilium's Envoy - would've meant
  hand-rolling ext_authz config with no official guide to follow.
- **Domain-level vs single-application forward auth**: Authentik supports
  both. Single-application mode needs a separate Provider + Middleware +
  extra routing rule *per app*, each bound to that app's own external
  host. Domain-level mode needs exactly one Provider for the whole
  `codeomelet.dev` domain, and every app just references the same shared
  Middleware. Since we already committed to one shared root domain with
  per-service subdomains, domain-level is the natural fit and a lot less
  repeated setup per app.
- **`argocd-server` insecure mode**: rather than fight Traefik
  backend-TLS/ServersTransport config to talk to argocd-server's
  self-signed cert, argocd-server now just serves plain HTTP directly
  (standard recommendation when TLS is already terminated upstream).

---

## Bugs hit and fixed (Talos/Terraform bootstrap)

1. **`rpc error: ... produced zero addresses`** on
   `talos_machine_configuration_apply`. Cause: `node` was fed
   `each.value.ip` from `local.controlplane_nodes` in `vm.tf`, which keeps
   the `/24` CIDR suffix (needed for Proxmox's `ip_config`), but the Talos
   gRPC client needs a bare IP. Fix: `node = split("/", each.value.ip)[0]`.

2. **`error decoding document v1alpha1/ResolverConfig ... unknown keys ...
   hostDNS`**. Cause: `providers.tf` was pinned to `siderolabs/talos`
   `0.12.0-alpha.5`, an alpha whose bundled Talos SDK targets `v1.14.0-
   alpha.1` - schema skew against the actual `v1.13.8` node image. Fix:
   pinned to stable `0.11.0` (SDK matches `v1.13.x`).

3. **`Kubernetes cluster unreachable: dial tcp :6443: connection refused`**
   on `helm_release.cilium`, right after `talos_machine_bootstrap`. Cause:
   `talos_cluster_kubeconfig` only proves the Talos API (port 50000) handed
   back a kubeconfig file - says nothing about whether kube-apiserver on
   the VIP is actually accepting connections yet (etcd quorum + static pod
   startup lag). Fix: added `time_sleep.wait_for_api` (60s) between
   `talos_cluster_kubeconfig` and anything that talks to `:6443`;
   `helm_release.cilium`'s `depends_on` points at it instead of bootstrap
   directly.

4. **Cilium agent pods `Init:CrashLoopBackOff`**, error `unable to apply
   caps: can't apply capabilities: operation not permitted` on
   `clean-cilium-state`. Cause: Talos permanently blocks `CAP_SYS_MODULE`/
   `CAP_SYS_BOOT` for every process, even privileged ones - Cilium's
   default Helm chart requests `SYS_MODULE`. Talos also doesn't auto-mount
   cgroupv2 the way the chart expects. Fix (`cilium.tf`): narrowed
   `securityContext.capabilities.ciliumAgent`/`.cleanCiliumState` to drop
   `SYS_MODULE`, set `cgroup.autoMount.enabled=false`,
   `cgroup.hostRoot=/sys/fs/cgroup`. Documented, standard Talos+Cilium
   requirement, not a one-off workaround.

**Status: all fixed, cluster confirmed healthy** (nodes Ready, Cilium
running, kube-apiserver/controller-manager/scheduler all up).

---

## Cloudflare Tunnel + Authentik rollout

### Manifests written (pushed to `clusters/dev/` in the repo, not yet all applied)

- `apps/sealed-secrets.yaml` - Sealed Secrets controller, chart
  `https://bitnami.github.io/sealed-secrets`, namespace `kube-system`
- `apps/traefik.yaml` - Traefik, ClusterIP only
- `apps/cloudflared.yaml` - wraps `cloudflared/` (plain manifests)
- `cloudflared/configmap.yaml` - tunnel ingress rules, routes every
  hostname to Traefik; catch-all `http_status:404`
- `cloudflared/deployment.yaml` - 2 replicas for HA
- `apps/authentik.yaml` - chart `goauthentik/authentik` pinned to
  `2026.5.6`, bundled postgresql + redis, secret_key/DB password wired via
  `existingSecret`/`secretKeyRef` (chart has no clean top-level "use this
  existing secret" for `secret_key` itself - done via explicit
  `server.env`/`worker.env` overrides, per goauthentik/authentik#12852,
  #2591)
- `apps/ingress.yaml` - wraps `ingress/`
- `ingress/authentik-forwardauth-middleware.yaml` - the one shared
  Traefik `Middleware`, domain-level forward auth
- `ingress/argocd-ingress.yaml` - `argocd.codeomelet.dev`, references the
  shared middleware, plain HTTP backend

### Still TODO (nothing below is applied yet)

- [ ] Confirm/replace `REPLACE_WITH_CURRENT_VERSION` placeholders:
      - `apps/sealed-secrets.yaml`: `helm search repo
        sealed-secrets/sealed-secrets --versions | head`
      - `apps/traefik.yaml`: `helm search repo traefik/traefik --versions
        | head`
- [ ] `cloudflared tunnel login` + `cloudflared tunnel create
      k8s-codeomelet`
- [ ] `cloudflared tunnel route dns` for `argocd.codeomelet.dev` and
      `auth.codeomelet.dev`
- [ ] Fill in `TUNNEL_ID_HERE` in `cloudflared/configmap.yaml`
- [ ] `git push` this repo (see commands below), let ArgoCD's root app
      pick up `clusters/dev/apps/*.yaml`
- [ ] Once `sealed-secrets` syncs: fetch its public cert
- [ ] Seal + commit `cloudflared/cloudflared-tunnel-credentials.sealed.yaml`
- [ ] Seal + commit `authentik/authentik-creds.sealed.yaml`
      (`secret_key` + `postgresql-password`)
- [ ] Verify `kubectl get svc -n traefik` and `kubectl get svc -n
      authentik` match the service names/ports hardcoded in
      `cloudflared/configmap.yaml` and
      `ingress/authentik-forwardauth-middleware.yaml` - chart defaults can
      differ by version
- [ ] Log into `auth.codeomelet.dev` as `akadmin` (bootstrap creds in the
      chart-generated secret), one-time setup: **Applications > Providers
      > Create > Proxy Provider > Forward auth (domain level)**, external
      host `https://auth.codeomelet.dev`, cookie domain `codeomelet.dev` ->
      bind to an Application -> assign to the embedded outpost
- [ ] Verify end-to-end: `https://argocd.codeomelet.dev` should redirect to
      Authentik login, then land back on ArgoCD after auth

### Exact commands

```bash
# push this repo for the first time
cd devcluster   # wherever you cloned github.com/JJDsylva/devcluster
git add clusters/dev
git commit -m "initial cloudflare tunnel + authentik rollout"
git push origin main

# 1. tunnel
cloudflared tunnel login
cloudflared tunnel create k8s-codeomelet

# 2. DNS
cloudflared tunnel route dns k8s-codeomelet argocd.codeomelet.dev
cloudflared tunnel route dns k8s-codeomelet auth.codeomelet.dev

# 3. sealed-secrets cert (once apps/sealed-secrets.yaml has synced)
export KUBECONFIG=./kubeconfig
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  > sealed-secrets-pub-cert.pem

# 4. seal tunnel credentials
kubectl create secret generic cloudflared-tunnel-credentials \
  --namespace cloudflared \
  --from-file=credentials.json=$HOME/.cloudflared/<TUNNEL_ID>.json \
  --dry-run=client -o yaml \
  | kubeseal --cert sealed-secrets-pub-cert.pem -o yaml \
  > clusters/dev/cloudflared/cloudflared-tunnel-credentials.sealed.yaml

# 5. seal authentik creds
SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')
PG_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
kubectl create secret generic authentik-creds \
  --namespace authentik \
  --from-literal=secret_key="$SECRET_KEY" \
  --from-literal=postgresql-password="$PG_PASSWORD" \
  --dry-run=client -o yaml \
  | kubeseal --cert sealed-secrets-pub-cert.pem -o yaml \
  > clusters/dev/authentik/authentik-creds.sealed.yaml

git add clusters/dev
git commit -m "add sealed secrets for cloudflared + authentik"
git push origin main
```

---

## Adding a new app behind auth (once the base above is working)

Because auth is domain-level, adding a new app needs **no new Authentik
Provider** - just:

1. Add a Service for the app (or it comes with one via its own chart).
2. Add a hostname line to `cloudflared/configmap.yaml`:
   `- hostname: <app>.codeomelet.dev` -> `service: http://traefik.traefik.
   svc.cluster.local:8000`
3. `cloudflared tunnel route dns k8s-codeomelet <app>.codeomelet.dev`
4. Add an Ingress in `ingress/` with:
   `traefik.ingress.kubernetes.io/router.middlewares:
   authentik-authentik-forwardauth@kubernetescrd`
   (same middleware every time - that's the point of domain-level mode)

No tunnel recreation, no new Authentik Provider, no Terraform changes.

---

## Future: genericizing this into a template repo (not started yet)

Goal: fork-and-go for someone else - edit **one** config file, run a render
step, get a working set of manifests for their own domain/cluster.

Planned approach: **Jinja2 templates + a single `config.yaml`**, rendered
by a small script, checked in as `Makefile` target `make render`.

Rough shape (to build once the base above is proven working):

```
config.example.yaml       <- copy to config.yaml, fill in your values
templates/
  clusters/dev/apps/authentik.yaml.j2
  clusters/dev/apps/cloudflared.yaml.j2
  clusters/dev/cloudflared/configmap.yaml.j2
  clusters/dev/ingress/*.yaml.j2
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

Not building this yet - revisit once the Cloudflare Tunnel + Authentik
rollout above is fully working end-to-end.
