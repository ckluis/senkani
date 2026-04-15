import SwiftUI

/// Sheet for creating a new workstream. User provides a name; branch and worktree are auto-generated.
struct NewWorkstreamSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var slug: String {
        GitWorktreeManager.slugify(name)
    }

    private var branchPreview: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        let date = fmt.string(from: Date())
        return slug.isEmpty ? "" : "feature/\(date)-\(slug)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            // Branch preview
            if !slug.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Branch")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(branchPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.cyan.opacity(0.08)))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Directory")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(".worktrees/\(slug)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Create") {
                    onCreate(name)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .disabled(slug.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360, height: 320)
    }
}
