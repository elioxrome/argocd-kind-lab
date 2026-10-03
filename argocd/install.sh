#!/usr/bin/env bash
# Instala/actualiza (idempotente) una instancia de ArgoCD por "tipo" en el
# cluster hub, cada una en su propio namespace argocd-<tipo>, vía Helm con el
# chart oficial argo-helm/argo-cd. Toda la config vive en base-values.yaml +
# instances/<tipo>/values.yaml: nada de ArgoCD queda hardcodeado en este script.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CHART_REPO="https://argoproj.github.io/argo-helm"
CHART_NAME="argo-cd"
CHART_VERSION="10.9.6" # appVersion ArgoCD v3.5.3, fijada para reproducibilidad
CONTEXT="kind-hub"

# it4t va primero siempre: es quien instala y posee los CRDs de Argo
# (cluster-scoped, ver instances/it4t/values.yaml). Las demás instancias
# llevan crds.install: false para no pelear por esa propiedad con Helm, así
# que necesitan que it4t ya exista.
# Por defecto solo it4t+digital (pruebas ligeras). Para sumar más:
#   ./install.sh it4t digital eop psc bcc
TIPOS=(it4t digital)
[[ $# -gt 0 ]] && TIPOS=("$@")

need() { command -v "$1" >/dev/null || { echo "ERROR: falta '$1' en el PATH"; exit 1; }; }
need helm
need kubectl

for tipo in "${TIPOS[@]}"; do
  ns="argocd-$tipo"
  values="$SCRIPT_DIR/instances/$tipo/values.yaml"
  [[ -f "$values" ]] || { echo "ERROR: no existe $values"; exit 1; }

  echo "[$tipo] namespace $ns"
  kubectl --context "$CONTEXT" create namespace "$ns" --dry-run=client -o yaml \
    | kubectl --context "$CONTEXT" apply -f -

  echo "[$tipo] helm upgrade --install argocd-$tipo (chart $CHART_NAME@$CHART_VERSION)"
  helm upgrade --install "argocd-$tipo" "$CHART_NAME" \
    --repo "$CHART_REPO" \
    --version "$CHART_VERSION" \
    --kube-context "$CONTEXT" \
    --namespace "$ns" \
    -f "$SCRIPT_DIR/base-values.yaml" \
    -f "$values" \
    --wait --timeout 5m
done

cat <<EOF

Instancias de ArgoCD listas: ${TIPOS[*]}
  UI:              ./argocd/port-forward.sh <tipo>
  Password admin:  ./argocd/admin-password.sh <tipo>
  Registrar el spoke del mismo tipo en una instancia:
                   ./argocd/register-clusters.sh <tipo>
EOF
