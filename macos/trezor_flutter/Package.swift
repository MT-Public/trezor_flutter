// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "trezor_flutter",
  platforms: [.macOS("10.15")],
  products: [
    .library(name: "trezor-flutter", targets: ["trezor_flutter"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "trezor_flutter",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      resources: [.process("PrivacyInfo.xcprivacy")],
      linkerSettings: [
        .linkedFramework("CoreBluetooth"),
        .linkedFramework("IOKit"),
      ]
    )
  ]
)
