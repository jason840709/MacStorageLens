import Foundation

struct AllocatedSizeMeasurement {
  var bytesByPath: [String: Int64] = [:]
  var incompletePaths: Set<String> = []
}

/// Keep the fast batch path, but never accept a partial `du` subtotal as a
/// complete size. A failed batch is retried per root so one protected directory
/// does not hide unrelated readable caches.
enum AllocatedSizeReader {
  static func measure(
    _ urls: [URL],
    run: ([String]) throws -> ProcessResult = {
      try ProcessRunner.run("/usr/bin/env", $0, timeout: 240)
    }
  ) throws -> AllocatedSizeMeasurement {
    var measurement = AllocatedSizeMeasurement()
    func record(_ result: ProcessResult, roots: [URL]) {
      let expected = Set(roots.map(\.path))
      if result.status == 0 {
        for line in result.stdoutString.split(separator: "\n") {
          guard let tab = line.firstIndex(of: "\t"), let kib = Int64(line[..<tab]),
            kib >= 0, kib <= Int64.max / 1024
          else { continue }
          let path = String(line[line.index(after: tab)...])
          if expected.contains(path) { measurement.bytesByPath[path] = kib * 1024 }
        }
      }
      measurement.incompletePaths.formUnion(expected.subtracting(measurement.bytesByPath.keys))
    }
    func arguments(_ roots: [URL]) -> [String] {
      ["LC_ALL=en_US.UTF-8", "/usr/bin/du", "-sk"] + roots.map(\.path)
    }
    for start in stride(from: 0, to: urls.count, by: 80) {
      let batch = Array(urls[start..<min(start + 80, urls.count)])
      let result = try run(arguments(batch))
      if result.status == 0 || batch.count == 1 {
        record(result, roots: batch)
      } else {
        for root in batch {
          do { record(try run(arguments([root])), roots: [root]) } catch {
            measurement.incompletePaths.insert(root.path)
          }
        }
      }
    }
    return measurement
  }
}
