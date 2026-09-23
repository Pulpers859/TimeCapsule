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

    /// Both targets that compile `AtticShared` must read the placeholder.
    ///
    /// The widget did not, for weeks, while the check that stood here passed:
    /// it only asked whether the placeholder appeared *anywhere* in the
    /// project, and the app and the test target were enough to satisfy it.
    /// So every sideloaded widget ran the free version whatever the app said,
    /// and the settings footer explaining the widget's behaviour described
    /// code that was never compiled into it. Found by reading strings out of
    /// a built IPA, not by any test. This names the targets instead.
    func testAppAndWidgetBothReadThePlaceholder() throws {
        let project = repositoryRoot()
            .appendingPathComponent("TimeCapsule.xcodeproj/project.pbxproj")
        guard let text = try? String(contentsOf: project, encoding: .utf8) else {
            throw XCTSkip("project.pbxproj not readable; repository layout changed.")
        }

        for target in ["TimeCapsule", "AtticWidget"] {
            let blocks = configurationBlocks(forTarget: target, in: text)
            XCTAssertEqual(
                blocks.count, 2,
                "Expected a Debug and a Release configuration for \(target); found \(blocks.count)."
            )
            for block in blocks {
                XCTAssertTrue(
                    block.contains("$(ATTIC_EXTRA_SWIFT_FLAGS)"),
                    """
                    A \(target) build configuration does not read \
                    $(ATTIC_EXTRA_SWIFT_FLAGS) in SWIFT_ACTIVE_COMPILATION_CONDITIONS, \
                    so a sideload build compiles this target without the sideload \
                    flag and the two processes disagree about Pro.
                    """
                )
            }
        }
    }

    /// The `XCBuildConfiguration` blocks belonging to one native target.
    ///
    /// Plain string searching rather than regular expressions so this runs
    /// the same on the Windows toolchain. An ID appears twice in the file: in
    /// the target's configuration list, indented four tabs, and at its own
    /// definition, indented two — which is the one wanted.
    private func configurationBlocks(forTarget target: String, in text: String) -> [String] {
        let marker = "/* Build configuration list for PBXNativeTarget \"\(target)\" */ = {"
        guard let list = text.range(of: marker),
              let open = text.range(of: "buildConfigurations = (", range: list.upperBound..<text.endIndex),
              let close = text.range(of: ");", range: open.upperBound..<text.endIndex) else {
            return []
        }

        let ids = text[open.upperBound..<close.lowerBound]
            .split(separator: "\n")
            .compactMap { line -> String? in
                let first = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first
                guard let id = first, id.count == 24 else { return nil }
                return String(id)
            }

        return ids.compactMap { id in
            guard let start = text.range(of: "\n\t\t\(id) /* "),
                  let end = text.range(of: "\n\t\t};", range: start.upperBound..<text.endIndex) else {
                return nil
            }
            return String(text[start.lowerBound..<end.upperBound])
        }
    }
}
