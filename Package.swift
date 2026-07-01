// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentPulse", targets: ["AgentPulseApp"]),
        .executable(name: "agentpulse-cli", targets: ["AgentPulseCLI"])
    ],
    targets: [
        .target(
            name: "AgentPulseCore",
            path: "Sources/AgentPulseCore"
        ),
        .target(
            name: "AgentPulseUI",
            dependencies: ["AgentPulseCore"],
            path: "Sources/AgentPulseUI"
        ),
        .executableTarget(
            name: "AgentPulseApp",
            dependencies: ["AgentPulseCore", "AgentPulseUI"],
            path: "Sources/AgentPulseApp"
        ),
        .executableTarget(
            name: "AgentPulseCLI",
            dependencies: ["AgentPulseCore"],
            path: "Sources/AgentPulseCLI"
        )
    ]
)
