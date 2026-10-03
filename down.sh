#!/usr/bin/env bash
set -euo pipefail
for c in hub digital eop psc bcc; do kind delete cluster --name "$c"; done
rm -rf "$(cd "$(dirname "$0")" && pwd)/.generated"
