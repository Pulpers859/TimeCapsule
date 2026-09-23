import XCTest

/// The sideload Pro switch must never be compilable into an App Store build.
///
/// It exists behind `#if ATTIC_SIDELOAD`, and that flag is supposed to reach
/// the compiler from exactly one place: the sideload workflow's command line.
/// If it were ever saved into the project's own build settings — one click in
/// Xcode's build settings pane would do it — every build, App Store builds
/// included, would ship a switch in Settings that unlocks Pro for free. That
/// is lost revenue from anyone who finds it, and an App Review rejection under
/// guideline 2.3.1 for a hidden feature.
///
/// Nothing at runtime would reveal the mistake, and CI builds would stay
/// green, so this reads the project files instead.
final class SideloadFlagTripwireTests: XCTestCase {
    private func repositoryRoot(file: StaticString = #filePath) -> URL {
        // .../Tests/TimeCapsuleCoreTests/<this file>
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every file that can hold a stored build setting or a scheme argument.
    private func projectFiles() throws -> [URL] {
        let root = repositoryRoot()
        let project = root.appendingPathComponent("TimeCapsule.xcodeproj")
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw XCTSkip("Project not found at \(project.path); repository layout changed.")
        }

        var files: [URL] = []
        for directory in [project, root.appendingPathComponent("Config")] {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator
            where ["pbxproj", "xcscheme", "xcconfig", "plist"].contains(url.pathExtension) {
                files.append(url)
            }
        }
        return files
    }

    func testSideloadFlagIsNotInAnyStoredBuildSetting() throws {
        let files = try projectFiles()
        XCTAssertFalse(files.isEmpty, "Found no project files to check.")

        for file in files {
            // Skipped rather than thrown on: a binary plist committed by
            // accident (per-user Xcode state, say) would otherwise fail this
            // test with a decoding error that says nothing about the flag.
            // Build settings are never stored in binary form.
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // The placeholder the workflow fills is allowed; the flag itself is
            // not. Strip the placeholder before looking.
            let withoutPlaceholder = text.replacingOccurrences(of: "ATTIC_EXTRA_SWIFT_FLAGS", with: "")
            XCTAssertFalse(
                withoutPlaceholder.contains("ATTIC_SIDELOAD"),
                """
                \(file.lastPathComponent) contains ATTIC_SIDELOAD. That flag \
                compiles in a Settings switch that unlocks Pro, and it must only \
                ever come from the sideload workflow's command line. Stored \
                here, it ships in App Store builds.
                """
            )
        }
    }

    /// The placeholder must still be wired, or the workflow's flag goes
    /// nowhere and a sideload build silently loses its switch.
    func testCompilationConditionsStillReadThePlaceholder() throws {
        let project = repositoryRoot()
            .appendingPathComponent("TimeCapsule.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
        XCTAssertTrue(
            text.contains("$(ATTIC_EXTRA_SWIFT_FLAGS)"),
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS no longer reads $(ATTIC_EXTRA_SWIFT_FLAGS)."
        )
    }
}
