// swift-tools-version:6.0
import PackageDescription

// libusb comes from Homebrew (`brew install libusb`) and is linked statically,
// so the built app does not depend on Homebrew at runtime.
let libusbPrefix = "/opt/homebrew/opt/libusb"

let package = Package(
    name: "MRCarve",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MRCarveKit", targets: ["MRCarveKit"]),
        .executable(name: "MRCarveApp", targets: ["MRCarveApp"]),
        .executable(name: "mrcarve-cli", targets: ["mrcarve-cli"]),
    ],
    targets: [
        .systemLibrary(name: "CLibUSB", path: "Sources/CLibUSB"),
        .target(
            name: "MRCarveKit",
            dependencies: ["CLibUSB"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(libusbPrefix)/include/libusb-1.0"])],
            linkerSettings: [
                .unsafeFlags(["\(libusbPrefix)/lib/libusb-1.0.a"]),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "MRCarveApp",
            dependencies: ["MRCarveKit"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "mrcarve-cli", dependencies: ["MRCarveKit"]),
        // Tests are a plain executable (`swift run mrcarve-tests`): with only the Command Line Tools
        // installed, SwiftPM can build but not run XCTest / swift-testing bundles.
        .executableTarget(name: "mrcarve-tests", dependencies: ["MRCarveKit"], path: "Tests/MRCarveKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
