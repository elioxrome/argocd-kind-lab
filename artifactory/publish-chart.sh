#!/usr/bin/env bash
# Publica el chart genérico (templates) como SU PROPIO artefacto
# versionado en Artifactory, independiente de cualquier microservicio.
# Esto se hace una vez por cada cambio al chart, no por cada
# microservicio/entorno (eso lo hace publish-release-chart.sh, que declara
# una dependencia a la versión publicada aquí).
#
# uso: publish-chart.sh <dir-del-chart> [ruta-en-el-repo]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CREDS_FILE="$ROOT_DIR/.generated/artifactory-admin.env"
CONTEXT="kind-hub"
NS="artifactory"
LOCAL_PORT=8082
REPO_KEY="example-repo-local"

CHART_DIR="${1:?uso: publish-chart.sh <dir-del-chart> [ruta-en-el-repo]}"
REPO_PATH="${2:-charts-values}"

[[ -f "$CHART_DIR/Chart.yaml" ]] || { echo "ERROR: no existe $CHART_DIR/Chart.yaml"; exit 1; }
[[ -f "$CREDS_FILE" ]] || { echo "ERROR: no existe $CREDS_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$CREDS_FILE"

command -v helm >/dev/null || { echo "ERROR: falta helm"; exit 1; }

WORK=$(mktemp -d)
kubectl --context "$CONTEXT" -n "$NS" port-forward svc/artifactory "$LOCAL_PORT:8082" >/tmp/artifactory-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT
sleep 4

PF_URL="http://localhost:$LOCAL_PORT/artifactory/$REPO_KEY/$REPO_PATH"
INCLUSTER_URL="http://artifactory.$NS.svc.cluster.local:8082/artifactory/$REPO_KEY/$REPO_PATH"

helm lint "$CHART_DIR"
helm package "$CHART_DIR" -d "$WORK"
TGZ=$(ls "$WORK"/*.tgz)
PKG=$(basename "$TGZ")

echo "[chart] subiendo $PKG a $PF_URL"
curl -sf -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" -X PUT "$PF_URL/$PKG" -T "$TGZ" >/dev/null

echo "[chart] actualizando index.yaml"
curl -sf -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" -o "$WORK/index.yaml" "$PF_URL/index.yaml" || true
if [[ -s "$WORK/index.yaml" ]]; then
  helm repo index "$WORK" --url "$INCLUSTER_URL" --merge "$WORK/index.yaml"
else
  helm repo index "$WORK" --url "$INCLUSTER_URL"
fi
curl -sf -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" -X PUT "$PF_URL/index.yaml" -T "$WORK/index.yaml" >/dev/null

echo "[chart] listo: $INCLUSTER_URL/$PKG"
