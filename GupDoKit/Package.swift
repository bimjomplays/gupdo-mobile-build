// swift-tools-version: 6.0
// GupDoKit: GupDo's plain logic (models, reminder/habit/event rules, the alert planner), with no SwiftUI or UIKit,
// so it builds and tests on Linux in seconds (`swift test --package-path GupDoKit`). The app target compiles these
// same files (ios/project.yml lists ../GupDoKit/Sources/GupDoKit), so nothing needs to be `public`.
import PackageDescription

let package = Package(
    name: "GupDoKit",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "GupDoKit", targets: ["GupDoKit"])],
    targets: [
        .target(name: "GupDoKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GupDoKitTests", dependencies: ["GupDoKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
