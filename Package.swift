// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Egasu",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "egasu", targets: ["EgasuApp"]),
        .executable(name: "egasu-cli", targets: ["EgasuCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        // 앱 내 자동 업데이트(appcast + EdDSA 서명). 2.9.4부터 dockless 앱의 업데이트 창 가림 수정.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.92.1")
    ],
    targets: [
        .target(
            name: "Egasu",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/Egasu",
            resources: [
                .process("Resources/Localization"),
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
            name: "EgasuApp",
            dependencies: ["Egasu"],
            path: "Sources/EgasuApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "EgasuCLI",
            dependencies: ["Egasu"],
            path: "Sources/EgasuCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "EgasuTests",
            dependencies: ["Egasu"],
            path: "Tests/EgasuTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "EgasuCLITests",
            dependencies: ["EgasuCLI"],
            path: "Tests/EgasuCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
