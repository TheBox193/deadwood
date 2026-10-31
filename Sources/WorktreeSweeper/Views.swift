import SwiftUI

struct ContentView: View {
  @StateObject private var model = SweeperModel()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Repository path", text: $model.repoPath)
          .textFieldStyle(.roundedBorder)
          .onSubmit(model.rescan)
        Button("Browse…", action: model.browse)
        Button(action: model.rescan) { Image(systemName: "arrow.clockwise") }
          .help("Rescan")
          .disabled(model.isLoading)
        ProgressView().controlSize(.small).opacity(model.isLoading ? 1 : 0)
      }
      .padding()

      TabView(selection: $model.tab) {
        WorktreesTable(model: model).tabItem { Text(countedTitle("Worktrees", model.worktrees.count)) }.tag(SweeperModel.Tab.worktrees)
        BranchesTable(model: model).tabItem { Text(countedTitle("Branches", model.branches.count)) }.tag(SweeperModel.Tab.branches)
        StashesTable(model: model).tabItem { Text(countedTitle("Stashes", model.stashes.count)) }.tag(SweeperModel.Tab.stashes)
      }
      .padding(.horizontal)
      .onDeleteCommand(perform: model.removeSelected)

      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
          ForEach(model.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1).help(warning)
          }
          if let recovery = model.recovery {
            HStack(spacing: 4) {
              Text(recovery.message).foregroundStyle(.secondary)
              if let command = recovery.command {
                Button { copyToClipboard(command) } label: { Image(systemName: "doc.on.doc") }
                  .buttonStyle(.borderless)
                  .help("Copy the git command that brings it back:\n\(command)")
              }
            }
          }
        }
        Spacer()
        if let scannedAt = model.scannedAt {
          Text("Scanned \(scannedAt.formatted(date: .omitted, time: .shortened))")
            .foregroundStyle(.secondary)
            .help("Deleting after 20 minutes asks for a rescan first")
        }
        if model.tab == .worktrees, let total = model.totalDiskDisplay {
          Text("· \(total) on disk")
            .foregroundStyle(.secondary)
            .help("Sum of du -sk over every worktree folder")
        }
      }
      .font(.callout)
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .onAppear(perform: model.rescan)
    .alert("Rescan needed", isPresented: $model.rescanNeeded) {
      Button("Rescan") { model.rescan() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This scan is more than 20 minutes old, so what it shows may no longer be true. Rescan before deleting anything.")
    }
    .confirmationDialog(model.pending?.title ?? "", isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }), presenting: model.pending) { action in
      Button(action.buttonLabel, role: .destructive, action: action.perform)
      Button("Cancel", role: .cancel) {}
    } message: { action in
      Text(action.message)
    }
  }

  private func countedTitle(_ name: String, _ count: Int) -> String { count == 0 ? name : "\(name) (\(count))" }
}

struct WorktreesTable: View {
  @ObservedObject var model: SweeperModel

  var body: some View {
    Table(model.worktrees, selection: $model.worktreeSelection, sortOrder: $model.worktreeSort) {
      TableColumn("Worktree", value: \.name) { w in Text(w.name).help(w.path) }
      TableColumn("Branch", value: \.branchLabel)
      TableColumn("Verdict", value: \.verdict) { w in VerdictBadge(verdict: w.verdict, pending: !w.audited) }.width(90)
      TableColumn("PR", value: \.status.mergedRank) { w in StatusIcon(status: w.status) }.width(50)
      TableColumn("Created", value: \.created) { w in Text(w.created.shortDisplay).help("Folder creation time") }.width(80)
      TableColumn("Last commit", value: \.status.lastCommitDate) { w in Text(w.status.lastCommitDate.shortDisplay) }.width(80)
      TableColumn("Size", value: \.diskSortKey) { w in
        Text(w.diskDisplay).monospacedDigit().help("Actual blocks used (du -sk); symlinks are not followed")
      }.width(70)
      TableColumn("Notes") { w in NotesText(w.notes) }
      TableColumn("") { w in
        HStack(spacing: 4) {
          if w.exists {
            Menu {
              ForEach(model.openTargets) { target in Button(target.name) { target.open(w.path) } }
            } label: {
              Image(systemName: "arrow.up.forward.app")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open in…")
          }
          if w.audited && w.verdict.canClean {
            TrashButton(help: "Remove worktree and delete its branch") { model.remove(w) }
          }
        }
      }.width(70)
    }
    .onChange(of: model.worktreeSort) { _, order in model.worktrees.sort(using: order) }
    .contextMenu(forSelectionType: Worktree.ID.self) { ids in
      if let w = model.worktrees.first(where: { ids.contains($0.id) }) {
        CopyButton("Copy worktree name", w.name)
        if let branch = w.branch { CopyButton("Copy branch name", branch) }
        CopyButton("Copy path", w.path)
        if let pr = w.status.pullRequest { CopyButton("Copy PR link", pr.url) }
      }
    }
  }
}

struct BranchesTable: View {
  @ObservedObject var model: SweeperModel

  var body: some View {
    Table(model.branches, selection: $model.branchSelection, sortOrder: $model.branchSort) {
      TableColumn("Branch", value: \.name)
      TableColumn("Verdict", value: \.verdict) { b in VerdictBadge(verdict: b.verdict, pending: !b.audited) }.width(90)
      TableColumn("PR", value: \.status.mergedRank) { b in StatusIcon(status: b.status) }.width(50)
      TableColumn("Last commit", value: \.status.lastCommitDate) { b in Text(b.status.lastCommitDate.shortDisplay) }.width(80)
      TableColumn("Notes") { b in NotesText(b.notes) }
      TableColumn("") { b in
        if b.audited && b.verdict.canClean && b.worktreePath == nil {
          TrashButton(help: "Delete branch") { model.delete(b) }
        }
      }.width(40)
    }
    .onChange(of: model.branchSort) { _, order in model.branches.sort(using: order) }
    .contextMenu(forSelectionType: LocalBranch.ID.self) { ids in
      if let b = model.branches.first(where: { ids.contains($0.id) }) {
        CopyButton("Copy branch name", b.name)
        if let pr = b.status.pullRequest { CopyButton("Copy PR link", pr.url) }
      }
    }
  }
}

struct StashesTable: View {
  @ObservedObject var model: SweeperModel

  var body: some View {
    Table(model.stashes, selection: $model.stashSelection, sortOrder: $model.stashSort) {
      TableColumn("Stash", value: \.message) { s in Text(s.message).help(s.message + "\n" + s.sha) }
      TableColumn("Branch") { s in Text(s.branch ?? "") }
      TableColumn("Verdict", value: \.verdict) { s in VerdictBadge(verdict: s.verdict, pending: !s.audited) }.width(90)
      TableColumn("Date", value: \.date) { s in Text(s.date.shortDisplay) }.width(80)
      TableColumn("Notes") { s in NotesText(s.notes) }
      TableColumn("") { s in
        if s.audited { TrashButton(help: "Drop stash") { model.drop(s) } }
      }.width(40)
    }
    .onChange(of: model.stashSort) { _, order in model.stashes.sort(using: order) }
    .contextMenu(forSelectionType: Stash.ID.self) { ids in
      if let s = model.stashes.first(where: { ids.contains($0.id) }) {
        CopyButton("Copy stash message", s.message)
        CopyButton("Copy SHA", s.sha)
        if let branch = s.branch { CopyButton("Copy branch name", branch) }
      }
    }
  }
}

// MARK: Shared pieces

struct NotesText: View {
  let notes: [String]
  init(_ notes: [String]) { self.notes = notes }
  var body: some View {
    Text(notes.joined(separator: " · ")).foregroundStyle(.secondary).help(notes.joined(separator: "\n"))
  }
}

struct CopyButton: View {
  let label: String
  let text: String
  init(_ label: String, _ text: String) { self.label = label; self.text = text }
  var body: some View { Button(label) { copyToClipboard(text) } }
}

struct TrashButton: View {
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) { Image(systemName: "trash") }
      .buttonStyle(.borderless)
      .help(help)
  }
}

struct StatusIcon: View {
  let status: BranchStatus

  var body: some View {
    HStack(spacing: 2) {
      if let pr = status.pullRequest {
        Button {
          if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        } label: {
          Image(systemName: pr.icon).foregroundStyle(prColor(pr))
        }
        .buttonStyle(.plain)
        if pr.isMerged && !status.fullyMerged {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption2)
        }
      } else if status.inBaseBranch {
        Image(systemName: "circle.and.line.horizontal").rotationEffect(.degrees(90)).foregroundStyle(.secondary)
      } else if status.ahead > 0 {
        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
      }
    }
    .help(tooltip)
  }

  private func prColor(_ pr: PullRequest) -> Color {
    if pr.isMerged { return .purple }
    if pr.isOpen { return .green }
    return .secondary
  }

  private var tooltip: String {
    var lines: [String] = []
    if let pr = status.pullRequest {
      if pr.isMerged {
        let when = pr.mergedAt.map { " on " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
        lines.append("PR #\(pr.number) merged\(when)")
        if !status.fullyMerged { lines.append("Has commits that were not part of the merged PR") }
      } else if pr.isOpen {
        lines.append("PR #\(pr.number) is open")
      } else {
        lines.append("PR #\(pr.number) was closed without merging")
      }
      lines.append("Click to open on GitHub")
    } else if status.inBaseBranch {
      lines.append("Same as main: no commits of its own, no PR")
    } else if status.ahead > 0 {
      lines.append("\(status.ahead) commit(s) not in main, no PR")
    }
    lines += ["", "Local: \(status.localLabel)", "Remote: \(status.remoteLabel)"]
    return lines.joined(separator: "\n")
  }
}

struct VerdictBadge: View {
  let verdict: Verdict
  var pending = false

  var body: some View {
    if pending {
      ProgressView().controlSize(.mini)
    } else {
      badge
    }
  }

  private var badge: some View {
    Text(verdict.rawValue)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(fill, in: Capsule())
      .foregroundStyle(text)
  }

  private var fill: Color {
    switch verdict {
    case .prunable, .dead: .red
    case .nearDead: .orange
    case .stale: .yellow
    case .inUse: .blue
    case .new: .mint
    case .active: .green
    case .main: .gray
    }
  }

  private var text: Color {
    switch verdict {
    case .stale, .new: .black.opacity(0.75)
    default: .white
    }
  }
}
