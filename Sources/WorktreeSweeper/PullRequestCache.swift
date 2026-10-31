import Foundation

actor PullRequestCache {
  private var byBranch: [String: [PullRequest]]
  private let bySha: [String: PullRequest]
  private var inFlight: [String: Task<[PullRequest], Never>] = [:]
  private let repo: String
  let failure: String?

  static func load(repo: String) async -> PullRequestCache {
    let bulk = await fetch(["--limit", "1000"], repo: repo)
    return PullRequestCache(repo: repo, prs: bulk.prs, failure: bulk.ok ? nil : bulk.stderr)
  }

  private init(repo: String, prs: [PullRequest], failure: String?) {
    self.repo = repo
    self.failure = failure
    byBranch = Dictionary(grouping: prs, by: \.branch)
    bySha = Dictionary(prs.map { ($0.headSha, $0) }, uniquingKeysWith: { a, b in Self.pick([a, b]) ?? a })
  }

  func lookup(sha: String) -> PullRequest? { bySha[sha] }

  func lookup(branch: String) async -> PullRequest? {
    if let cached = byBranch[branch] { return Self.pick(cached) }
    let task = inFlight[branch] ?? Task { [repo] in await Self.fetch(["--head", branch, "--limit", "10"], repo: repo).prs }
    inFlight[branch] = task
    let prs = await task.value
    byBranch[branch] = prs
    inFlight[branch] = nil
    return Self.pick(prs)
  }

  private static func pick(_ prs: [PullRequest]) -> PullRequest? {
    prs.first(where: \.isMerged) ?? prs.first(where: \.isOpen) ?? prs.first
  }

  private static func fetch(_ args: [String], repo: String) async -> (ok: Bool, prs: [PullRequest], stderr: String) {
    let fields = "number,state,headRefName,headRefOid,url,mergedAt"
    let result = await Shell.run("gh", ["pr", "list", "--state", "all", "--json", fields] + args, cwd: repo)
    guard result.ok else { return (false, [], result.stderr) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (true, (try? decoder.decode([PullRequest].self, from: Data(result.stdout.utf8))) ?? [], "")
  }
}
