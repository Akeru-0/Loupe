#!/bin/sh
# Builds Loupe and opens it on the dev library (never on ~/Pictures).
set -e
cd "$(dirname "$0")/.."
scripts/bundle.sh debug
open build/Loupe.app --args -LoupeRoot "$PWD/dev-library"
