// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Switchmypanes",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (geometry, snapping, MRU, key classification). No UI, fully testable.
        .target(name: "SwitchmypanesCore"),
        // The menu bar app itself.
        .executableTarget(name: "Switchmypanes", dependencies: ["SwitchmypanesCore"]),
        // Test runner. XCTest / swift-testing are not available with only the Command Line Tools,
        // so the checks are a plain executable: `swift run CoreChecks`.
        .executableTarget(name: "CoreChecks", dependencies: ["SwitchmypanesCore"]),
    ]
)
