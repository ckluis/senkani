import SwiftUI

/// Sheet for creating a new workstream. User provides a name; the
/// sheet discloses the worktree path + auto-generated branch name
/// the create operation will produce, and lets the operator override
/// the branch name. This is the create-time half of the destructive-
/// action contract closed by the paired remove dialogs.
struct NewWorkstreamSheet: View {
    let project: ProjectModel?
    let onCreate: (_ name: String, _ branchOverride: String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var branchOverride: String = ""

    init(project: ProjectModel? = nil,
         onCreate: @escaping (_ name: String, _ branchOverride: String?) -> Void) {
        self.project = project
        self.onCreate = onCreate
    }

    private var slug: String {
        GitWorktreeManager.slugify(name)
    }

    private var defaultBranchName: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        let date = fmt.string(from: Date())
        return slug.isEmpty ? "" : "feature/\(date)-\(slug)"
    }

    private var effectiveBranchName: String {
        branchOverride.isEmpty ? defaultBranchName : branchOverride
    }

    private var worktreeRoot: String {
        if let p = project { return p.path }
        return "<project root>"
    }

    private var worktreePath: String {
        "\(worktreeRoot)/.worktrees/\(slug)"
    }

    private var projectIsGitRepo: Bool {
        guard let p = project else { return true }
        return GitWorktreeManager.isGitRepo(path: p.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Workstream")
                .font(.system(size: 16, weight: .semibold))

            Text("Creates a git worktree with an isolated terminal. Each workstream gets its own branch, index, and cache.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                TextField("e.g. auth refactor", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            if !slug.isEmpty {
                if projectIsGitRepo {
                    // Disclosure block: what `git worktree add` will create.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This will create:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 10))
                            Text(worktreePath)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(.cyan)
                                .font(.system(size: 10))
                            Text(effectiveBranchName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.cyan)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.gray.opacity(0.06)))

                    // Editable branch override.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Branch (override)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField(defaultBranchName, text: $branchOverride)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                } else {
                    // Non-git project: degenerate workstream (sidebar only).
                    Text("This project is not a git repository; the workstream will only have sidebar/UI state.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.orange.opacity(0.06)))
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Create") {
                    let override = branchOverride.trimmingCharacters(in: .whitespaces)
                    onCreate(name, override.isEmpty ? nil : override)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .disabled(slug.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
    }
}
