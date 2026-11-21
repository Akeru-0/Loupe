#!/bin/sh
# Builds Loupe and opens it on the real library, ~/Pictures. (The test fixtures stay in dev-library; to open
# them instead: open build/Loupe.app --args -LoupeRoot "$PWD/dev-library")
set -e
cd "$(dirname "$0")/.."
scripts/bundle.sh debug
open build/Loupe.app --args -LoupeRoot "$HOME/Pictures"
