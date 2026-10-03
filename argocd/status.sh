#!/usr/bin/env bash
# Estado de las instancias de ArgoCD en el hub.
# Sin argumentos: resumen de todas (namespace, pods, releases).
# Con un tipo: detalle de pods de esa instancia.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONTEXT="kind-hub"
TIPOS=(it4t digital eop psc bcc)

if [[ $# -gt 0 ]]; then
  tipo="$1"
  ns="argocd-$tipo"
  echo "== $tipo (ns=$ns) =="
  kubectl --context "$CONTEXT" get namespace "$ns" >/dev/null 2>&1 \
    || { echo "  no instalada: falta el namespace. Corre ./install.sh $tipo"; exit 1; }
  kubectl --context "$CONTEXT" -n "$ns" get pods
  exit 0
fi

echo "Contexto: $CONTEXT"
echo
printf "%-10s %-18s %-8s %s\n" TIPO NAMESPACE PODS NOTA
for tipo in "${TIPOS[@]}"; do
  ns="argocd-$tipo"
  nota=""
  [[ "$tipo" == "it4t" ]] && nota="dueño de los CRDs; sin spoke propio"
  if ! kubectl --context "$CONTEXT" get namespace "$ns" >/dev/null 2>&1; then
    printf "%-10s %-18s %-8s %s\n" "$tipo" "$ns" "-" "no instalada"
    continue
  fi
  total=$(kubectl --context "$CONTEXT" -n "$ns" get pods --no-headers 2>/dev/null | wc -l)
  ready=$(kubectl --context "$CONTEXT" -n "$ns" get pods --no-headers 2>/dev/null \
    | awk -F'[ /]+' '$2==$3 && $2!=""{c++} END{print c+0}')
  printf "%-10s %-18s %-8s %s\n" "$tipo" "$ns" "$ready/$total" "$nota"
done

echo
echo "Detalle de una instancia: ./status.sh <tipo>"
echo "Todos los pods de Argo de un vistazo: kubectl --context $CONTEXT get pods -A -l app.kubernetes.io/part-of=argocd"
