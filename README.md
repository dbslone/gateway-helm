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
