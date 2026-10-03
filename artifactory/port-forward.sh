#!/usr/bin/env bash
# Expone la UI/API de Artifactory en localhost.
set -euo pipefail

PORT="${1:-8082}"
CONTEXT="kind-hub"
NS="artifactory"

echo "UI Artifactory: http://localhost:$PORT  (usuario: admin / password: password, te pide cambiarla)"
kubectl --context "$CONTEXT" -n "$NS" port-forward svc/artifactory "$PORT:8082"
