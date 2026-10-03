#!/usr/bin/env bash
# Empaqueta y publica un chart "wrapper" por microservicio/entorno: lo único
# que mantiene a mano este script como entrada es un values.yaml (más un
# Chart.yaml generado de pocas líneas) — el chart con los templates se
# declara como DEPENDENCIA de Helm (documenta qué versión del chart
# genérico usa esta release) y se empaqueta junto, vendorizado localmente.
#
# Por qué vendorizado en vez de resuelto por red (`helm dependency update`
# contra Artifactory): el index.yaml de Artifactory lleva la URL
# in-cluster (la que necesita ArgoCD, que corre dentro del cluster) — y esa
# URL no la puede resolver quien publica desde su laptop. No hay una sola
# URL que sirva para los dos. Empaquetar localmente evita el problema: no
# hace falta bajar nada por HTTP para armar el wrapper.
#
# uso: publish-release-chart.sh <dir-chart-generico> <values.yaml> <nombre> <version> [ruta-en-el-repo]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CREDS_FILE="$ROOT_DIR/.generated/artifactory-admin.env"
CONTEXT="kind-hub"
NS="artifactory"
LOCAL_PORT=8082
REPO_KEY="example-repo-local"

GENERIC_CHART_DIR="${1:?uso: publish-release-chart.sh <dir-chart-generico> <values.yaml> <nombre> <version> [ruta-repo]}"
VALUES_FILE="${2:?falta <values.yaml>}"
RELEASE_NAME="${3:?falta <nombre> (ej: mc-user-fastapi)}"
RELEASE_VERSION="${4:?falta <version> (ej: 0.1.0-dev)}"
REPO_PATH="${5:-charts-values}"

[[ -f "$GENERIC_CHART_DIR/Chart.yaml" ]] || { echo "ERROR: no existe $GENERIC_CHART_DIR/Chart.yaml"; exit 1; }
[[ -f "$VALUES_FILE" ]] || { echo "ERROR: no existe $VALUES_FILE"; exit 1; }
[[ -f "$CREDS_FILE" ]] || { echo "ERROR: no existe $CREDS_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$CREDS_FILE"

command -v helm >/dev/null || { echo "ERROR: falta helm"; exit 1; }

DEP_CHART_NAME=$(python3 -c "import yaml; print(yaml.safe_load(open('$GENERIC_CHART_DIR/Chart.yaml'))['name'])")
DEP_CHART_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('$GENERIC_CHART_DIR/Chart.yaml'))['version'])")

WORK=$(mktemp -d)
kubectl --context "$CONTEXT" -n "$NS" port-forward svc/artifactory "$LOCAL_PORT:8082" >/tmp/artifactory-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT
sleep 4

PF_URL="http://localhost:$LOCAL_PORT/artifactory/$REPO_KEY/$REPO_PATH"
INCLUSTER_URL="http://artifactory.$NS.svc.cluster.local:8082/artifactory/$REPO_KEY/$REPO_PATH"

echo "[release] armando wrapper $RELEASE_NAME-$RELEASE_VERSION (depende de $DEP_CHART_NAME@$DEP_CHART_VERSION)"
# src/ (el wrapper que se construye) separado de dist/ (el .tgz final a
# publicar): tras empaquetar la dependencia queda un .tgz cacheado dentro
# de src/.../charts/, y no queremos que `helm repo index` lo levante como
# si fuera otro chart publicado.
mkdir -p "$WORK/src" "$WORK/dist"
RELEASE_DIR="$WORK/src/$RELEASE_NAME"
mkdir -p "$RELEASE_DIR/charts"

cat > "$RELEASE_DIR/Chart.yaml" <<EOF
apiVersion: v2
name: $RELEASE_NAME
description: Values de $RELEASE_NAME, publicado por CI. El chart real es la dependencia.
type: application
version: $RELEASE_VERSION
dependencies:
  - name: $DEP_CHART_NAME
    version: "$DEP_CHART_VERSION"
    repository: "$INCLUSTER_URL"
EOF

echo "[release] vendorizando la dependencia (empaquetado local, sin red)"
helm package "$GENERIC_CHART_DIR" -d "$RELEASE_DIR/charts" >/dev/null

# $VALUES_FILE es un values.yaml "plano" (las mismas claves que espera el
# chart genérico). Helm anida los values de una dependencia bajo la clave
# con su nombre, así que se envuelve automáticamente bajo "$DEP_CHART_NAME:".
python3 - "$VALUES_FILE" "$DEP_CHART_NAME" "$RELEASE_DIR/values.yaml" <<'PYEOF'
import sys, yaml
values_path, dep_name, out_path = sys.argv[1:4]
with open(values_path) as f:
    flat = yaml.safe_load(f) or {}
with open(out_path, "w") as f:
    yaml.safe_dump({dep_name: flat}, f, sort_keys=False)
PYEOF

helm lint "$RELEASE_DIR"

echo "[release] empaquetando"
helm package "$RELEASE_DIR" -d "$WORK/dist"
TGZ=$(ls "$WORK/dist/$RELEASE_NAME"-*.tgz)
PKG=$(basename "$TGZ")

echo "[release] subiendo $PKG a $PF_URL"
curl -sf -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" -X PUT "$PF_URL/$PKG" -T "$TGZ" >/dev/null

echo "[release] actualizando index.yaml"
curl -sf -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" -o "$WORK/dist/index.yaml" "$PF_URL/index.yaml" || true
if [[ -s "$WORK/dist/index.yaml" ]]; then
  helm repo index "$WORK/dist" --url "$INCLUSTER_URL" --merge "$WORK/dist/index.yaml"
else
  helm repo index "$WORK/dist" --url "$INCLUSTER_URL"
fi
curl -sf -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" -X PUT "$PF_URL/index.yaml" -T "$WORK/dist/index.yaml" >/dev/null

echo "[release] listo: $INCLUSTER_URL/$PKG"
