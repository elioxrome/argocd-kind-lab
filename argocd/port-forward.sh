#!/usr/bin/env bash
# Expone la UI de una instancia de ArgoCD en localhost vía kubectl port-forward.
set -euo pipefail

TIPO="${1:?uso: port-forward.sh <tipo> [puerto-local]  (ej: port-forward.sh digital 8443)}"
PORT="${2:-8443}"
CONTEXT="kind-hub"
NS="argocd-$TIPO"
SVC="svc/argocd-$TIPO-server"

echo "UI ArgoCD [$TIPO]: https://localhost:$PORT  (usuario: admin)"
kubectl --context "$CONTEXT" -n "$NS" port-forward "$SVC" "$PORT:443"
