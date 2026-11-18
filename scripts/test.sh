#!/bin/sh
# Runs the test suite with the Command Line Tools only (no Xcode).
# SwiftPM's default build system can't find Swift Testing's macro plugin here,
# so use the native build system and point it at the CLT frameworks explicitly.
# Usage: scripts/test.sh [--filter <SuiteOrTestName>] [other swift test args]
set -e
CLT=/Library/Developer/CommandLineTools
FW="$CLT/Library/Developer/Frameworks"
exec swift test --build-system native \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"
