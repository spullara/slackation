#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/xcode.sh" build "$@"
