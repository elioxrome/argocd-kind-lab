#!/usr/bin/env bash
# Imprime el password inicial de admin de una instancia de ArgoCD.
set -euo pipefail

TIPO="${1:?uso: admin-password.sh <tipo>  (ej: admin-password.sh digital)}"
CONTEXT="kind-hub"
NS="argocd-$TIPO"

kubectl --context "$CONTEXT" -n "$NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
