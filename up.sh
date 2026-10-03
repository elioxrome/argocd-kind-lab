#!/usr/bin/env bash
# Levanta hub + spokes por tipo con kind y prepara el acceso del hub a cada
# spoke. IT4T no tiene spoke: sus Applications se despliegan directamente en
# el hub (igual que en el diagrama).
# Por defecto solo levanta digital (+ hub) para pruebas ligeras; pasa otros
# tipos como argumentos para sumar spokes: ./up.sh digital eop psc bcc
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SPOKES=(digital)
[[ $# -gt 0 ]] && SPOKES=("$@")
CLUSTERS=(hub "${SPOKES[@]}")
OUT_DIR="$SCRIPT_DIR/.generated"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"   # opcional: fija la versión de k8s, p.ej. kindest/node:vX.Y.Z

need() { command -v "$1" >/dev/null || { echo "ERROR: falta '$1' en el PATH"; exit 1; }; }
need docker; need kind; need kubectl
mkdir -p "$OUT_DIR"

create_cluster() {
  local name=$1
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    echo "[$name] ya existe, lo salto"
    return
  fi
  local args=(--name "$name" --config "$SCRIPT_DIR/kind/$name.yaml" --wait 120s)
  [[ -n "$KIND_NODE_IMAGE" ]] && args+=(--image "$KIND_NODE_IMAGE")
  kind create cluster "${args[@]}"
}

# En cada spoke: ServiceAccount con cluster-admin + token de larga duración
# que el ArgoCD del hub usará para desplegar en él.
setup_spoke_access() {
  local name=$1 ctx="kind-$1" token="" ca=""

  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

  # El token controller rellena el Secret de forma asíncrona
  for _ in $(seq 1 30); do
    token=$(kubectl --context "$ctx" -n kube-system get secret argocd-manager-token \
      -o jsonpath='{.data.token}' 2>/dev/null || true)
    [[ -n "$token" ]] && break
    sleep 1
  done
  [[ -z "$token" ]] && { echo "ERROR: [$name] el token no se generó"; exit 1; }

  ca=$(kubectl --context "$ctx" -n kube-system get secret argocd-manager-token \
    -o jsonpath='{.data.ca\.crt}')   # ya viene en base64, que es lo que espera caData
  token=$(printf '%s' "$token" | base64 --decode)

  # Secret de registro de cluster para el/los ArgoCD del hub.
  # Dirección interna de la red docker "kind", no 127.0.0.1.
  # Sin namespace: cada instancia de ArgoCD vive en su propio namespace
  # (argocd-<tipo>) y es argocd/register-clusters.sh quien decide dónde
  # aplicarlo con `kubectl -n`.
  cat > "$OUT_DIR/cluster-$name.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$name
  labels:
    argocd.argoproj.io/secret-type: cluster
    role: spoke
    tipo: $name
type: Opaque
stringData:
  name: $name
  server: https://$name-control-plane:6443
  config: |
    {"bearerToken": "$token", "tlsClientConfig": {"caData": "$ca"}}
EOF
  echo "[$name] secret de cluster generado en $OUT_DIR/cluster-$name.yaml"
}

# Comprueba que un pod del hub resuelve y alcanza el API server del spoke
check_connectivity() {
  local name=$1
  echo "[hub -> $name] comprobando conectividad..."
  kubectl --context kind-hub run "netcheck-$name" --rm -i --quiet --restart=Never \
    --image=curlimages/curl --pod-running-timeout=2m -- \
    -sk --max-time 5 "https://$name-control-plane:6443/version" \
    && echo "[hub -> $name] OK" \
    || { echo "ERROR: el hub no alcanza $name-control-plane:6443"; exit 1; }
}

for c in "${CLUSTERS[@]}"; do create_cluster "$c"; done
for s in "${SPOKES[@]}"; do setup_spoke_access "$s"; done
for s in "${SPOKES[@]}"; do check_connectivity "$s"; done

contexts=""
for c in "${CLUSTERS[@]}"; do contexts+="kind-$c, "; done

cat <<EOF

Infra base lista.
  Contextos:    ${contexts%, }
  Secrets de cluster generados en $OUT_DIR/ (aún sin registrar en ningún ArgoCD)
  IT4T no tiene spoke: sus Applications van directo al hub.

Siguiente paso (IaC de ArgoCD, ver ./argocd/):
  ./argocd/install.sh it4t ${SPOKES[*]} # instala solo las instancias que necesitas
  ./argocd/register-clusters.sh <tipo> # registra el spoke del mismo tipo (p.ej. digital -> digital)
  ./argocd/port-forward.sh <tipo>      # UI en https://localhost:8443
  ./argocd/admin-password.sh <tipo>    # password inicial de admin
EOF
