// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ZipPrint",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ZipPrint", targets: ["ZipPrint"]),
        .library(name: "ZipPrinterKit", targets: ["ZipPrinterKit"]),
    ],
    targets: [
        .target(
            name: "ZipPrinterKit",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .executableTarget(
            name: "ZipPrint",
            dependencies: ["ZipPrinterKit"]
        ),
        .testTarget(
            name: "ZipPrinterKitTests",
            dependencies: ["ZipPrinterKit"]
        ),
    ]
)
