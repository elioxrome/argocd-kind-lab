#!/usr/bin/env bash
# Instala Artifactory OSS en el hub (namespace "artifactory"), vía el chart
# oficial de JFrog. Una sola instancia, no una por "tipo" (es infraestructura
# compartida, no algo que se repita por tenant).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CHART_REPO="https://charts.jfrog.io"
CHART_NAME="artifactory-oss"
CHART_VERSION="107.161.26" # appVersion 7.161.26, fijada para reproducibilidad
CONTEXT="kind-hub"
NS="artifactory"

need() { command -v "$1" >/dev/null || { echo "ERROR: falta '$1' en el PATH"; exit 1; }; }
need helm
need kubectl
need openssl

kubectl --context "$CONTEXT" create namespace "$NS" --dry-run=client -o yaml \
  | kubectl --context "$CONTEXT" apply -f -

# Artifactory 7.x exige Master Key + Join Key para que sus servicios internos
# (router, frontend, etc.) se autentiquen entre sí. Se generan una sola vez
# y se guardan como Secret: si ya existe, se reusa (regenerarlas rompe el
# join entre servicios ya desplegados).
if ! kubectl --context "$CONTEXT" -n "$NS" get secret artifactory-mandatory-keys >/dev/null 2>&1; then
  echo "[artifactory] generando master-key/join-key (primera vez)"
  kubectl --context "$CONTEXT" -n "$NS" create secret generic artifactory-mandatory-keys \
    --from-literal=master-key="$(openssl rand -hex 32)" \
    --from-literal=join-key="$(openssl rand -hex 32)"
fi

helm upgrade --install artifactory "$CHART_NAME" \
  --repo "$CHART_REPO" \
  --version "$CHART_VERSION" \
  --kube-context "$CONTEXT" \
  --namespace "$NS" \
  -f "$SCRIPT_DIR/values.yaml" \
  --set global.masterKeySecretName=artifactory-mandatory-keys \
  --set global.joinKeySecretName=artifactory-mandatory-keys \
  --wait --timeout 10m

cat <<EOF

Artifactory listo en ns=$NS.
  UI/API: ./artifactory/port-forward.sh
  Usuario admin por defecto: admin / password (cámbialo en el primer login)
EOF
