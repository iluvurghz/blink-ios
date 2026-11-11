// swift-tools-version:5.9
import PackageDescription

// Ядро Blink для iOS: офлайн-движок, клиент API, логика экранов. Без UIKit и SwiftUI, поэтому
// собирается и тестируется на Linux (дёшево), а приложение подключает его как локальный пакет.
let package = Package(
    name: "BlinkCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "BlinkCore", targets: ["BlinkCore"]),
    ],
    targets: [
        .target(name: "BlinkCore"),
        .testTarget(name: "BlinkCoreTests", dependencies: ["BlinkCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
