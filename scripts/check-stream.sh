#!/bin/zsh
# Compiles the streaming code with the checks in Tests/ and runs them. Prints "all checks passed" or fails.
# Later tasks add their Clarion/ files to SOURCES and their check files in Tests/ are picked up by the glob.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(
  Clarion/AMF0.swift
  Clarion/FLV.swift
  Clarion/RTMPChunk.swift
  Clarion/RTMPConnection.swift
  Clarion/StreamVideoEncoder.swift
  Clarion/StreamAudio.swift
)

mkdir -p build
swiftc -swift-version 5 -parse-as-library -sdk "$(xcrun --show-sdk-path)" \
  "${SOURCES[@]}" Tests/*.swift -o build/stream-checks
build/stream-checks "$PWD"
