#!/usr/bin/env bash
# Run the hgt conformance suite. Thin wrapper so you don't need to know it's bats.
set -euo pipefail
cd "$(dirname "$0")/.."
exec bats test/
