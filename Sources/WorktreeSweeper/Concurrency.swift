import Foundation

/// Runs `transform` over `items` with at most `limit` in flight, handing each result to `onEach` as it lands.
func mapConcurrently<T: Sendable, R: Sendable>(_ items: [T], limit: Int = 8, _ transform: @escaping @Sendable (T) async -> R,
                                               onEach: (R) async -> Void) async {
  await withTaskGroup(of: R.self) { group in
    var next = 0
    while next < min(limit, items.count) { group.addTask { [item = items[next]] in await transform(item) }; next += 1 }
    for await result in group {
      if Task.isCancelled { group.cancelAll(); return }
      await onEach(result)
      if next < items.count { group.addTask { [item = items[next]] in await transform(item) }; next += 1 }
    }
  }
}

func auditAll<T: Sendable>(_ items: [T], _ audit: @escaping @Sendable (T) async -> T) async -> [T] {
  var out: [T] = []
  await mapConcurrently(items, audit) { out.append($0) }
  return out
}
