#!/usr/bin/env bash
# Registra clusters spoke (generados por ../up.sh en .generated/cluster-*.yaml)
# como clusters externos de una instancia concreta de ArgoCD, aplicando el
# Secret correspondiente en su namespace (argocd-<tipo>).
#
# Por defecto cada tipo gestiona su propio spoke del mismo nombre
# (digital -> cluster "digital", eop -> cluster "eop", ...), igual que en el
# diagrama. IT4T no tiene spoke propio, pásalo explícito si alguna vez lo
# necesitas: register-clusters.sh it4t <cluster>.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
GEN_DIR="$ROOT_DIR/.generated"
CONTEXT="kind-hub"

TIPO="${1:?uso: register-clusters.sh <tipo> [cluster...]  (ej: register-clusters.sh digital, o register-clusters.sh digital digital eop)}"
shift || true
CLUSTERS=("$@")
NS="argocd-$TIPO"

[[ -d "$GEN_DIR" ]] || { echo "ERROR: no existe $GEN_DIR (corre ../up.sh primero)"; exit 1; }

[[ ${#CLUSTERS[@]} -eq 0 ]] && CLUSTERS=("$TIPO")

files=()
for c in "${CLUSTERS[@]}"; do files+=("$GEN_DIR/cluster-$c.yaml"); done
for f in "${files[@]}"; do
  [[ -f "$f" ]] || { echo "ERROR: no existe $f (¿corriste ../up.sh? ¿tiene '$TIPO' spoke propio?)"; exit 1; }
done

kubectl --context "$CONTEXT" get namespace "$NS" >/dev/null 2>&1 \
  || { echo "ERROR: namespace $NS no existe. Corre primero ./install.sh $TIPO"; exit 1; }

for f in "${files[@]}"; do
  echo "[$TIPO] registrando $(basename "$f") en ns=$NS"
  kubectl --context "$CONTEXT" -n "$NS" apply -f "$f"
done
