# API-GATEWAY HELM CHART (ingress only)

The Node.js api-gateway pod has been **removed**. API traffic terminates on
**mvn-backend** (`mvn-backend-simplefbo-backend:8003`). See
[`mvn-backend/CUTOVER.md`](../mvn-backend/CUTOVER.md).

This chart now only manages:

- Istio `Gateway` `api-gateway` (namespace `istio-ingress`) — the cluster ingress
  listener (HTTP/HTTPS, TLS hosts)
- `VirtualService` `api-gateway-vs` — routes `api.simplefbo.com` / `api.dbslone.com`
  to `mvn-backend-simplefbo-backend.simplefbo.svc.cluster.local:8003`
- `VirtualService` `grafana-ui` — routes `graph.dbslone.com` to
  `grafana.monitoring.svc.cluster.local:80`
- ConfigMap `etcd-disk-grafana-dashboard` (namespace `monitoring`) — Grafana
  dashboard for the etcd WAL-fsync failure that took the cluster down
- ConfigMap `simplefbo-backend-clerk-env` — reference env fragment for the backend

## graph.dbslone.com (Cloudflare Access)

Login is Cloudflare Access. After GitHub, Grafana signs that email in with the `Cf-Access-Authenticated-User-Email` header (`auto_sign_up`, org role Admin). `/login` is not redirected to `/`, because the Sign in button opens `/login` and that bounce returns to the same screen. The auth env is in
[`grafana-auth-values.yaml`](grafana-auth-values.yaml) and is already merged
into Helm release `grafana` in namespace `monitoring`. Do not upgrade that
release with only that file.

Already in place:

- **Certificate** — `simplefbo-cf-tls` includes `*.dbslone.com`.
- **DNS** — proxied `A` `graph.dbslone.com` → `76.95.114.68` (same VIP as `jobs.dbslone.com`).
- **Kemp** — that VIP already forwards `graph.dbslone.com` to Istio. No new virtual service.
- **Access** — self-hosted application `Grafana` on `graph.dbslone.com`. The only IdP is GitHub. The allow rule is the reusable policy **Allow dbslone** (email `dbslone@gmail.com`), the same policy as `jobs.dbslone.com`. The Access API rejected a GitHub-username include.
- **Static assets** — application `Grafana public assets` on `graph.dbslone.com/public` with a Bypass policy. Grafana loads `/public/build/*.js` without cookies (`ChunkLoadError: Loading chunk 192 failed` if Access returns the login page). `/` and `/api` stay behind GitHub login.

## etcd disk dashboard

ConfigMap `etcd-disk-grafana-dashboard` in namespace `monitoring` is the
dashboard for the spinning-disk outage: WAL fsync p99 (yellow at etcd's 10ms
warning, red at 100ms), backend commit, API-server etcd write latency (the
path Patroni uses to renew its leader lock), and proposals backing up.

Grafana loads it only when release `grafana` has the dashboard sidecar on.
Those keys are in [`grafana-auth-values.yaml`](grafana-auth-values.yaml).
Merge them with `--reuse-values`. Do not upgrade that release with only that
file.

Check the cluster path (bypasses Access) and the public login:

```bash
curl -skI --resolve graph.dbslone.com:443:192.168.7.105 https://graph.dbslone.com
curl -sI https://graph.dbslone.com
```

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
