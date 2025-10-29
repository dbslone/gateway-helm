# API-GATEWAY HELM CHART

## Build Chart
- Use the command ` helm package ./charts/simplefbo-api-gateway` and push to github

## Rollback Instructions (ArgoCD)

This chart is configured with `revisionHistoryLimit: 2` to enable quick rollbacks. Here are the different ways to rollback when using ArgoCD:

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

### Method 3: kubectl (Fastest - Direct Kubernetes)
```bash
# Rollback to previous deployment revision
kubectl rollout undo deployment/<deployment-name>

# Rollback to specific revision
kubectl rollout history deployment/<deployment-name>
kubectl rollout undo deployment/<deployment-name> --to-revision=<n>

# Check rollback status
kubectl rollout status deployment/<deployment-name>
```

### Method 4: Helm (If managing outside ArgoCD)
```bash
# List release history
helm history <release-name>

# Rollback to previous revision
helm rollback <release-name>

# Rollback to specific revision
helm rollback <release-name> <revision-number>
```

### Rollback Benefits with revisionHistoryLimit: 2
- **Instant rollback**: Previous ReplicaSet is kept ready for immediate activation
- **No image re-pulling**: Uses cached images from previous deployment
- **Faster recovery**: Avoids Helm chart re-rendering and ArgoCD sync delays
- **Clean environment**: Automatically cleans up old ReplicaSets beyond the limit

### Post-Rollback Verification
```bash
# Check pod status
kubectl get pods -l app.kubernetes.io/name=gateway

# Check ReplicaSet status
kubectl get rs -l app.kubernetes.io/name=gateway

# Check application health
kubectl get pods -l app.kubernetes.io/name=gateway -o wide
```