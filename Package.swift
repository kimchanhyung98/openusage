// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenUsage",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "OpenUsage", targets: ["OpenUsageApp"]),
        .executable(name: "openusage-cli", targets: ["OpenUsageCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        // 앱 내 자동 업데이트(appcast + EdDSA 서명). 2.9.4부터 dockless 앱의 업데이트 창 가림 수정.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.62.0")
    ],
    targets: [
        .target(
            name: "OpenUsage",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/OpenUsage",
            resources: [
                .copy("Resources/ProviderIcons"),
                .copy("Resources/pricing_supplement.json"),
                .copy("Resources/pricing_litellm_snapshot.json"),
                .copy("Resources/pricing_models_dev_snapshot.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "OpenUsageApp",
            dependencies: ["OpenUsage"],
            path: "Sources/OpenUsageApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "OpenUsageCLI",
            dependencies: ["OpenUsage"],
            path: "Sources/OpenUsageCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OpenUsageTests",
            dependencies: ["OpenUsage"],
            path: "Tests/OpenUsageTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OpenUsageCLITests",
            dependencies: ["OpenUsageCLI"],
            path: "Tests/OpenUsageCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
