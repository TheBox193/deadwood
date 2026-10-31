import AppKit
import SwiftUI

@main
struct WorktreeSweeperApp: App {
  init() {
    if let index = CommandLine.arguments.firstIndex(of: "--audit") {
      let repo = CommandLine.arguments.dropFirst(index + 1).first ?? SweeperModel.defaultRepo
      Task { await Self.printAudit(repo: (repo as NSString).expandingTildeInPath); exit(0) }
      RunLoop.main.run()
    }
    NSApplication.shared.setActivationPolicy(.regular)
  }

  var body: some Scene {
    WindowGroup("Worktree Sweeper") {
      ContentView()
        .frame(minWidth: 1000, minHeight: 500)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
    .defaultSize(width: 1400, height: 800)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Worktree Sweeper") { Self.showAbout() }
      }
    }
  }

  private static func showAbout() {
    let year = Calendar.current.component(.year, from: Date())
    let font = NSFont.systemFont(ofSize: 12)
    let credits = NSMutableAttributedString(string: "Made by Jonathan Stassen\n", attributes: [.font: font])
    credits.append(NSAttributedString(string: "jstassen.com", attributes: [.font: font, .link: "https://jstassen.com"]))
    NSApplication.shared.orderFrontStandardAboutPanel(options: [
      .applicationName: "Worktree Sweeper",
      .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
      .credits: credits,
      NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© \(year) Jonathan Stassen",
    ])
  }

  private static func printAudit(repo: String) async {
    let auditor = await Auditor(repo: repo)
    for warning in auditor.warnings { print("!! \(warning)") }
    let worktrees = await Auditor.auditAll(Auditor.discoverWorktrees(repo: repo)) { await auditor.audit($0) }
    let branches = await Auditor.auditAll(Auditor.discoverBranches(repo: repo, worktrees: worktrees)) { await auditor.audit($0) }
    let stashes = await Auditor.auditAll(Auditor.discoverStashes(repo: repo)) { await auditor.audit($0) }
    printSection("Worktrees", worktrees.map { ($0.verdict, $0.status.lastCommitDate, "\($0.name) [\($0.branchLabel)]", $0.notes) })
    printSection("Branches", branches.map { ($0.verdict, $0.status.lastCommitDate, $0.name, $0.notes) })
    printSection("Stashes", stashes.map { ($0.verdict, $0.date, $0.message, $0.notes) })
  }

  private static func printSection(_ title: String, _ rows: [(Verdict, Date, String, [String])]) {
    print("== \(title)")
    for (verdict, date, label, notes) in rows.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
      let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
      print("\(verdict.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(day)  \(label)  \(notes.joined(separator: ", "))")
    }
    print()
  }
}
