import Foundation

@main
struct CleanupProtectionAudit {
  static func main() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("Protection-\(UUID().uuidString)")
    let config = home.appendingPathComponent(".config/mole")
    try fm.createDirectory(at: config, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let whitelist = config.appendingPathComponent("whitelist")
    try Data("~/Library/Caches/Keep*/important\n~/.Trash\nFINDER_METADATA\n".utf8).write(
      to: whitelist)
    func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    let policy = CleanupProtectionPolicy(home: home, activeBundleIDs: ["com.example.Busy"])
    expect(
      policy.reason(for: home.path + "/Library/Caches/KeepOne") != nil,
      "parent removal protects descendant")
    expect(
      policy.reason(for: home.path + "/Library/Caches/KeepOne/other") == nil,
      "unrelated sibling allowed")
    expect(
      policy.reason(for: home.path + "/Library/Caches/KeepOne/important/file") != nil,
      "glob descendant protected")
    expect(
      policy.reason(for: home.path + "/Library/Caches/com.example.Busy") != nil,
      "active app protected")
    expect(
      policy.reason(for: home.path + "/Library/Caches/com.example.BusyOther") == nil,
      "bundle ID boundary exact")
    expect(
      policy.reason(for: home.path + "/.cache/huggingface/hub/model") != nil, "models protected")
    expect(
      policy.reason(for: home.path + "/Library/Caches/ms-playwright/chromium") != nil,
      "browser runtime protected")
    expect(
      policy.reason(for: home.path + "/Documents/.DS_Store") != nil, "Finder metadata sentinel")
    expect(
      policy.reason(for: home.path, includingDescendants: false) == nil, "traversal may enter home")
    try fm.createDirectory(
      at: home.appendingPathComponent(".cache/huggingface"), withIntermediateDirectories: true)
    let alias = home.appendingPathComponent("cache-alias")
    try fm.createSymbolicLink(
      at: alias, withDestinationURL: home.appendingPathComponent(".cache/huggingface"))
    expect(policy.reason(for: alias.path) != nil, "symlink target protected")
    try Data("$(touch /tmp/never-execute)\n".utf8).write(to: whitelist)
    let invalid = CleanupProtectionPolicy(home: home, activeBundleIDs: [])
    expect(
      invalid.reason(for: home.path + "/Library/Caches/Anything") != nil
        && !invalid.notices.isEmpty, "invalid config fails closed")
    try fm.removeItem(at: whitelist)
    try fm.createSymbolicLink(
      at: whitelist, withDestinationURL: home.appendingPathComponent("missing"))
    expect(
      CleanupProtectionPolicy(home: home, activeBundleIDs: []).reason(for: home.path + "/cache")
        != nil, "dangling config fails closed")
    print("CleanupProtectionAudit: 12 / 12 passed")
  }
}
