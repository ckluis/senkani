import Foundation

// MARK: - PlaybookFileStore
//
// Phase H+2c — disk backing for applied `LearnedWorkflowPlaybook`s.
// Namespace isolation (Schneier): `.senkani/playbooks/learned/` so a
// learned playbook can never shadow a shipped skill (which lives in
// `.senkani/skills/` or the global `~/.senkani/skills/`).
//
// Pattern mirrors `ContextFileStore`: atomic write, secret re-scan on
// every read, safe-slug title guarantee from `LearnedContextDoc.sanitizeTitle`.

public enum PlaybookFileStore {

    /// Directory under project root where applied playbooks live.
    public static let dirName: String = ".senkani/playbooks/learned"

    public static func directory(for projectRoot: String) -> String {
        projectRoot + "/" + dirName
    }

    public static func pathFor(projectRoot: String, playbook: LearnedWorkflowPlaybook) -> String {
        directory(for: projectRoot) + "/" + playbook.title + ".md"
    }

    public static func write(
        playbook: LearnedWorkflowPlaybook,
        projectRoot: String,
        now: Date = Date()
    ) throws {
        let dir = directory(for: projectRoot)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let path = pathFor(projectRoot: projectRoot, playbook: playbook)
        let sanitizedDesc = LearnedWorkflowPlaybook.sanitizeDescription(playbook.description)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let header = "<!-- senkani workflow playbook · id=\(playbook.id) · applied=\(iso.string(from: now)) -->\n\n"

        // Render steps as a human-readable numbered list below the description.
        var stepsSection = "\n## Steps\n\n"
        for (idx, step) in playbook.steps.enumerated() {
            stepsSection += "\(idx + 1). **\(step.toolName)** — `\(step.example)`\n"
        }
        try (header + sanitizedDesc + stepsSection).write(
            toFile: path, atomically: true, encoding: .utf8)
    }

    public static func read(projectRoot: String, title: String) -> String? {
        let safeTitle = LearnedContextDoc.sanitizeTitle(title)
        let path = directory(for: projectRoot) + "/" + safeTitle + ".md"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return LearnedWorkflowPlaybook.sanitizeDescription(raw)
    }

    public static func remove(projectRoot: String, title: String) {
        let safeTitle = LearnedContextDoc.sanitizeTitle(title)
        let path = directory(for: projectRoot) + "/" + safeTitle + ".md"
        try? FileManager.default.removeItem(atPath: path)
    }
}
