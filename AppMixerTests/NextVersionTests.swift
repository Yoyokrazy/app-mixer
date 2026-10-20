import Foundation
import Testing

/// Runs `scripts/next-version.sh` against throwaway git repositories.
@Suite("next-version.sh")
struct NextVersionTests {
    struct CommandError: Error, CustomStringConvertible {
        let description: String
    }

    /// A temporary repository, isolated from the user's git config (signing, hooks, identity).
    final class Repo {
        static let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/next-version.sh")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("next-version-\(UUID().uuidString)")

        init() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try git("init", "-q", "-b", "main")
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        @discardableResult
        func run(_ executable: URL, _ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = url
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            for role in ["AUTHOR", "COMMITTER"] {
                environment["GIT_\(role)_NAME"] = "App Mixer Tests"
                environment["GIT_\(role)_EMAIL"] = "tests@example.com"
            }
            process.environment = environment
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CommandError(description: "\(executable.lastPathComponent) \(arguments) failed: \(String(decoding: errorData, as: UTF8.self))")
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @discardableResult
        func git(_ arguments: String...) throws -> String {
            try run(URL(fileURLWithPath: "/usr/bin/git"), arguments)
        }

        func commit(_ messages: String...) throws {
            for message in messages {
                try git("commit", "-q", "--allow-empty", "-m", message)
            }
        }

        func nextVersion(force: Bool = false) throws -> String {
            try run(Self.script, force ? ["--force"] : [])
        }

        /// A repository whose latest release is `tag`.
        static func released(_ tag: String) throws -> Repo {
            let repo = try Repo()
            try repo.commit("feat: initial release")
            try repo.git("tag", tag)
            return repo
        }
    }

    @Test(arguments: [
        (["fix: a"], "1.4.3"),
        (["refactor(mixer): a"], "1.4.3"),
        (["perf: a", "docs: b"], "1.4.3"),
        (["feat: a"], "1.5.0"),
        (["feat(ui): a"], "1.5.0"),
        (["fix: a", "feat: b", "chore: c"], "1.5.0"),
        (["feat!: a"], "2.0.0"),
        (["fix(api)!: a"], "2.0.0"),
        (["fix: a\n\nBREAKING CHANGE: b"], "2.0.0"),
        (["fix: a\n\nBREAKING-CHANGE: b"], "2.0.0"),
        (["docs: a"], ""),
        (["test: a", "tests: b", "ci: c", "chore: d", "style: e", "docs(readme): f"], ""),
    ])
    func bumpsFromTheLatestTag(commits: [String], expected: String) throws {
        let repo = try Repo.released("v1.4.2")
        for message in commits { try repo.commit(message) }
        #expect(try repo.nextVersion() == expected)
    }

    @Test func firstReleaseCountsUpFromZero() throws {
        let fix = try Repo()
        try fix.commit("fix: a")
        #expect(try fix.nextVersion() == "0.0.1")

        let feature = try Repo()
        try feature.commit("fix: a", "feat: b")
        #expect(try feature.nextVersion() == "0.1.0")
    }

    @Test func nothingToReleaseRightAfterATag() throws {
        let repo = try Repo.released("v0.2.0")
        #expect(try repo.nextVersion() == "")
        #expect(try repo.nextVersion(force: true) == "", "--force still needs a commit")
    }

    @Test func forceTurnsMaintenanceIntoAPatch() throws {
        let repo = try Repo.released("v0.2.0")
        try repo.commit("docs: a", "test: b")
        #expect(try repo.nextVersion(force: true) == "0.2.1")
    }

    @Test func forceDoesNotDowngradeARealBump() throws {
        let repo = try Repo.released("v0.2.0")
        try repo.commit("feat: a")
        #expect(try repo.nextVersion(force: true) == "0.3.0")
    }

    @Test func mergeCommitsAreIgnored() throws {
        let repo = try Repo.released("v0.2.0")
        try repo.git("checkout", "-q", "-b", "topic")
        try repo.commit("test: add tests")
        try repo.git("checkout", "-q", "main")
        try repo.git("merge", "-q", "--no-ff", "topic", "-m", "Merge pull request #4 from Yoyokrazy/topic")
        #expect(try repo.nextVersion() == "")

        try repo.git("checkout", "-q", "-b", "fix")
        try repo.commit("fix: a")
        try repo.git("checkout", "-q", "main")
        try repo.git("merge", "-q", "--no-ff", "fix", "-m", "Merge pull request #5 from Yoyokrazy/fix")
        #expect(try repo.nextVersion() == "0.2.1")
    }

    @Test func onlyVersionTagsMarkReleases() throws {
        let repo = try Repo.released("v0.1.0")
        try repo.commit("feat: a")
        try repo.git("tag", "v0.2.0")
        try repo.commit("fix: b")
        try repo.git("tag", "nightly")
        try repo.git("tag", "v9")
        #expect(try repo.nextVersion() == "0.2.1")
    }
}
