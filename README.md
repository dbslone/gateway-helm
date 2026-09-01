# API-GATEWAY HELM CHART (ingress only)

The Node.js api-gateway pod has been **removed**. API traffic terminates on
**mvn-backend** (`mvn-backend-simplefbo-backend:8003`). See
[`mvn-backend/CUTOVER.md`](../mvn-backend/CUTOVER.md).

This chart now only manages:

- Istio `Gateway` `api-gateway` (namespace `istio-ingress`) — the cluster ingress
  listener (HTTP/HTTPS, TLS hosts)
- `VirtualService` `api-gateway-vs` — routes `api.simplefbo.com` / `api.dbslone.com`
  to `mvn-backend-simplefbo-backend.simplefbo.svc.cluster.local:8003`
- ConfigMap `simplefbo-backend-clerk-env` — reference env fragment for the backend

## Stalwart (mail)

`charts/stalwart` deploys Stalwart in namespace `mail` so you can host mail for
`dbslone.com` and `simplefbo.com`. ArgoCD Application: `applications/stalwart.yaml`.

1. Create the recovery-admin Secret (once, not in git):

   ```bash
   kubectl create namespace mail --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n mail create secret generic stalwart-recovery-admin \
     --from-literal=username=admin \
     --from-literal=password='choose-a-strong-password' \
     --from-literal=STALWART_RECOVERY_ADMIN='admin:choose-a-strong-password'
   ```

2. Register the app with ArgoCD (once). Use the **same repository URL** as
   simplefbo-api-gateway (`https://github.com/dbslone/gateway-helm.git`). Do not
   add a new repo and do not `helm install`. Application name **and** Helm
   release name must be lowercase `stalwart`.

   UI: New App → project `simplefbo` → pick the existing `gateway-helm` repo →
   PATH `charts/stalwart` → Application Name `stalwart` → Helm Release Name
   `stalwart` → namespace `mail`. The chart does not create a Namespace
   (project `simplefbo` forbids it); `CreateNamespace=true` or `kubectl create
   namespace mail` is enough.

   Or apply:

   ```bash
   kubectl apply -f applications/stalwart.yaml
   ```

3. Admin UI is `https://mail.dbslone.com` and `https://mail.simplefbo.com` through
   the existing Istio Gateway (`istio-ingress/api-gateway`, TLS secret
   `simplefbo-cf-tls`). Add those hostnames to the Cloudflare origin cert if they
   are not already covered.

4. SMTP/IMAP stay off Istio. `stalwart-mail` is a LoadBalancer on `10.0.1.5`.
   The UDM reaches **`192.168.7.105`**, so the StatefulSet uses `hostPort` for
   25/465/587/993 and is pinned to node `serv1-kube`. Confirm the node name
   with `kubectl get nodes -o wide`. After push, ArgoCD should show a
   StatefulSet diff — Sync it (auto-sync is off). Then `nc -vz 192.168.7.105 25`.
   Point MX/A at the public WAN IP (grey cloud). Add domains in `/admin`.

`config.json` only names the RocksDB DataStore. Everything else lives in the
database after bootstrap — ArgoCD is not meant to reconcile it.

## IMPORTANT

### Backend Clerk env

`values.yaml` → `backendClerk` enables ConfigMap `simplefbo-backend-clerk-env`, which
contains a pasteable Deployment `env` fragment for `CLERK_JWT_KEY` and
`CLERK_WEBHOOK_SECRET` (from secret `gateway-pg` by default). Add those entries to
the **simplefbo-backend** Deployment in `simplefbo-backend-helm`.

## IMPORTANT
The `Gateway` defined in this project should be the only one. When new services need to be added you should add under the ports and define the VirtualService in the applications helm project.

## Build Chart
- Use the command ` helm package ./charts/simplefbo-api-gateway` and push to github

## Rollback Instructions (ArgoCD)

### Method 1: ArgoCD UI (Recommended)
1. Open ArgoCD UI and navigate to your application
2. Click on the **History** tab
3. Select the previous revision you want to rollback to
4. Click **Rollback** button
5. Confirm the rollback operation

### Method 2: ArgoCD CLI
```bash
# List application history
argocd app history <app-name>

# Rollback to previous revision
argocd app rollback <app-name>

# Rollback to specific revision
argocd app rollback <app-name> <revision-number>
```

### Method 3: Helm (If managing outside ArgoCD)
```bash
# List release history
helm history <release-name>

# Rollback to previous revision
helm rollback <release-name>

# Rollback to specific revision
helm rollback <release-name> <revision-number>
```

Note: rolling back past chart `0.2.0` restores the api-gateway Deployment/Service —
only do that intentionally (it also requires the `gateway-pg` secret and the
`davidbslone/simplefbo-api-gateway` image to still be available).
