#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Sources/Models.swift Sources/AirPodsDecoder.swift Tests/AirPodsDecoderTests.swift \
  -o .build/AirPodsDecoderTests
.build/AirPodsDecoderTests
swiftc Sources/TargetSelection.swift Tests/TargetSelectionTests.swift \
  -o .build/TargetSelectionTests
.build/TargetSelectionTests
swiftc Sources/Models.swift Sources/ChargingWarning.swift Tests/ChargingWarningTests.swift \
  -o .build/ChargingWarningTests
.build/ChargingWarningTests
swiftc -parse-as-library -framework AppKit -framework CoreBluetooth \
  -emit-module -emit-module-path .build/PodCharge.swiftmodule \
  Sources/Models.swift Sources/AirPodsDecoder.swift Sources/TargetSelection.swift Sources/AirPodsMonitor.swift
