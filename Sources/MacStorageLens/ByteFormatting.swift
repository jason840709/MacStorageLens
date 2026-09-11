import Foundation

extension Int64 {
  var formattedBytes: String {
    ByteCountFormatter.storageLens.string(fromByteCount: self)
  }
}

extension ByteCountFormatter {
  static let storageLens: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    formatter.zeroPadsFractionDigits = false
    return formatter
  }()
}

extension String {
  var shellSingleQuoted: String {
    "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
