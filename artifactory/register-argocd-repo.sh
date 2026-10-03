#!/usr/bin/env bash
# Registra Artifactory (repo example-repo-local/charts-values) como repo
# Helm de una instancia de ArgoCD, con credenciales (Artifactory no permite
# acceso anónimo). Necesario una vez por instancia que vaya a usarlo como
# fuente multi-source ($values).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CREDS_FILE="$ROOT_DIR/.generated/artifactory-admin.env"
CONTEXT="kind-hub"

TIPO="${1:?uso: register-argocd-repo.sh <tipo>  (ej: register-argocd-repo.sh it4t)}"
NS="argocd-$TIPO"
# URL interna del cluster (el repo-server de ArgoCD corre dentro del hub,
# no en tu laptop: no sirve localhost).
REPO_URL="http://artifactory.artifactory.svc.cluster.local:8082/artifactory/example-repo-local/charts-values"

[[ -f "$CREDS_FILE" ]] || { echo "ERROR: no existe $CREDS_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$CREDS_FILE"

kubectl --context "$CONTEXT" get namespace "$NS" >/dev/null 2>&1 \
  || { echo "ERROR: namespace $NS no existe. Corre primero ../argocd/install.sh $TIPO"; exit 1; }

kubectl --context "$CONTEXT" -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: artifactory-values-charts
  namespace: $NS
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: artifactory-values-charts
  url: $REPO_URL
  username: $ARTIFACTORY_USER
  password: $ARTIFACTORY_PASSWORD
EOF

echo "[$TIPO] repo Artifactory registrado en $NS -> $REPO_URL"
