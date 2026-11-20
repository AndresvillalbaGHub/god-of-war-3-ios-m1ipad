// SPDX-License-Identifier: GPL-3.0-or-later
// Save data manager for Documents/gow3/user/savedata and local backups in Documents/gow3/user/backups:
// creates/restores/deletes snapshots, exports a standard .zip via UIActivityViewController, and
// imports .zip archives or folders via UIDocumentPickerViewController with automatic safety backups.
import Compression
import Foundation
import UIKit
import UniformTypeIdentifiers

enum Gow3SaveError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case .message(let text): return text
    }
  }
}

private enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    var c = UInt32(index)
    for _ in 0..<8 {
      c = (c & 1) != 0 ? (0xedb8_8320 ^ (c >> 1)) : (c >> 1)
    }
    return c
  }

  static func compute(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { raw in
      var crc: UInt32 = 0xffff_ffff
      for byte in raw {
        crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
      }
      return crc ^ 0xffff_ffff
    }
  }
}

private extension Data {
  mutating func appendLE16(_ v: UInt16) {
    append(UInt8(v & 0xff))
    append(UInt8((v >> 8) & 0xff))
  }

  mutating func appendLE32(_ v: UInt32) {
    append(UInt8(v & 0xff))
    append(UInt8((v >> 8) & 0xff))
    append(UInt8((v >> 16) & 0xff))
    append(UInt8((v >> 24) & 0xff))
  }

  func u16(_ offset: Int) -> UInt16 {
    UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
  }

  func u32(_ offset: Int) -> UInt32 {
    UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }
}

enum Gow3SaveManager {
  private static var activeImportCoordinator: SaveImportCoordinator?

  private static var userRoot: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("gow3/user", isDirectory: true)
  }

  static var savesDir: URL { userRoot.appendingPathComponent("savedata", isDirectory: true) }
  static var backupsDir: URL { userRoot.appendingPathComponent("backups", isDirectory: true) }

  private static func timestampTag() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private static func sanitizeBackupName(_ raw: String?) -> String {
    let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let source = trimmed.isEmpty ? "backup-\(timestampTag())" : trimmed
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
    let cleaned = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    var name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    if name.isEmpty || name == "." || name == ".." {
      name = "backup-\(timestampTag())"
    }
    return String(name.prefix(64))
  }

  private static func validatedBackupURL(name: String) throws -> URL {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
      throw Gow3SaveError.message("Invalid backup name.")
    }
    return backupsDir.appendingPathComponent(name, isDirectory: true)
  }

  private static func treeStats(at root: URL) -> (fileCount: Int, totalBytes: Int64) {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
          let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
          ) else {
      return (0, 0)
    }
    var count = 0
    var bytes: Int64 = 0
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true else { continue }
      count += 1
      bytes += Int64(values.fileSize ?? 0)
    }
    return (count, bytes)
  }

  static func summary() -> [String: Any] {
    let fm = FileManager.default
    let current = treeStats(at: savesDir)
    var backups: [[String: Any]] = []
    if let entries = try? fm.contentsOfDirectory(
      at: backupsDir,
      includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) {
      for url in entries {
        guard let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]),
              vals.isDirectory == true else { continue }
        let stats = treeStats(at: url)
        let date = vals.contentModificationDate ?? vals.creationDate ?? Date(timeIntervalSince1970: 0)
        backups.append([
          "name": url.lastPathComponent,
          "createdAt": date.timeIntervalSince1970 * 1000.0,
          "fileCount": stats.fileCount,
          "totalBytes": Int(stats.totalBytes),
        ])
      }
      backups.sort { ($0["createdAt"] as? Double ?? 0) > ($1["createdAt"] as? Double ?? 0) }
    }
    return [
      "hasSaves": current.fileCount > 0,
      "fileCount": current.fileCount,
      "totalBytes": Int(current.totalBytes),
      "backups": backups,
    ]
  }

  static func createBackup(name: String? = nil) throws -> [String: Any] {
    let fm = FileManager.default
    let stats = treeStats(at: savesDir)
    guard stats.fileCount > 0 else {
      throw Gow3SaveError.message("No savedata files to back up yet.")
    }
    try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
    let baseName = sanitizeBackupName(name)
    var folderName = baseName
    var dest = backupsDir.appendingPathComponent(folderName, isDirectory: true)
    var suffix = 2
    while fm.fileExists(atPath: dest.path) {
      folderName = "\(baseName)-\(suffix)"
      dest = backupsDir.appendingPathComponent(folderName, isDirectory: true)
      suffix += 1
    }
    try fm.copyItem(at: savesDir, to: dest)
    let copied = treeStats(at: dest)
    return [
      "name": folderName,
      "createdAt": Date().timeIntervalSince1970 * 1000.0,
      "fileCount": copied.fileCount,
      "totalBytes": Int(copied.totalBytes),
    ]
  }

  private static func replaceSavedata(withNormalizedSavesDir sourceDir: URL, safetyPrefix: String) throws -> String {
    let fm = FileManager.default
    let incoming = treeStats(at: sourceDir)
    guard incoming.fileCount > 0 else {
      throw Gow3SaveError.message("Selected save data folder is empty.")
    }
    try fm.createDirectory(at: userRoot, withIntermediateDirectories: true)
    var autoBackupName: String?
    if treeStats(at: savesDir).fileCount > 0 {
      let auto = try createBackup(name: "\(safetyPrefix)-\(timestampTag())")
      autoBackupName = auto["name"] as? String
    }
    let stage = userRoot.appendingPathComponent(".savedata-stage-\(UUID().uuidString)", isDirectory: true)
    try fm.copyItem(at: sourceDir, to: stage)
    if fm.fileExists(atPath: savesDir.path) {
      try fm.removeItem(at: savesDir)
    }
    do {
      try fm.moveItem(at: stage, to: savesDir)
    } catch {
      try? fm.removeItem(at: stage)
      throw error
    }
    if let autoBackupName {
      return "Restored \(incoming.fileCount) save files (previous saves kept as \(autoBackupName))."
    }
    return "Loaded \(incoming.fileCount) save files."
  }

  static func restoreBackup(name: String, gameStarted: Bool) throws -> String {
    guard !gameStarted else {
      throw Gow3SaveError.message("Relaunch the app before restoring save data.")
    }
    let backupURL = try validatedBackupURL(name: name)
    guard FileManager.default.fileExists(atPath: backupURL.path) else {
      throw Gow3SaveError.message("Backup '\(name)' not found.")
    }
    _ = try replaceSavedata(withNormalizedSavesDir: backupURL, safetyPrefix: "pre-restore")
    return "Restored backup '\(name)'."
  }

  static func deleteBackup(name: String) throws -> String {
    let backupURL = try validatedBackupURL(name: name)
    let fm = FileManager.default
    guard fm.fileExists(atPath: backupURL.path) else {
      throw Gow3SaveError.message("Backup '\(name)' not found.")
    }
    try fm.removeItem(at: backupURL)
    return "Deleted backup '\(name)'."
  }

  static func exportSaves(completion: @escaping (Result<String, Error>) -> Void) {
    let stats = treeStats(at: savesDir)
    guard stats.fileCount > 0 else {
      completion(.failure(Gow3SaveError.message("No savedata files to export yet.")))
      return
    }
    let archiveURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("olympus-gow3-saves-\(timestampTag()).zip")
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try writeZipArchive(of: savesDir, rootPrefix: "savedata", to: archiveURL)
      } catch {
        try? FileManager.default.removeItem(at: archiveURL)
        DispatchQueue.main.async {
          completion(.failure(error))
        }
        return
      }
      DispatchQueue.main.async {
        guard let top = Gow3GameViewController.topViewController() else {
          try? FileManager.default.removeItem(at: archiveURL)
          completion(.failure(Gow3SaveError.message("No window to present export sheet.")))
          return
        }
        let activity = UIActivityViewController(activityItems: [archiveURL], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
          popover.sourceView = top.view
          popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
          popover.permittedArrowDirections = []
        }
        activity.completionWithItemsHandler = { _, completed, _, activityError in
          try? FileManager.default.removeItem(at: archiveURL)
          if let activityError {
            completion(.failure(activityError))
          } else {
            completion(.success(completed ? "Exported \(stats.fileCount) save files." : "Export cancelled."))
          }
        }
        top.present(activity, animated: true)
      }
    }
  }

  static func importSaves(gameStarted: Bool, completion: @escaping (Result<String, Error>) -> Void) {
    guard !gameStarted else {
      completion(.failure(Gow3SaveError.message("Relaunch the app before importing save data.")))
      return
    }
    DispatchQueue.main.async {
      guard let top = Gow3GameViewController.topViewController() else {
        completion(.failure(Gow3SaveError.message("No window to present file picker.")))
        return
      }
      let coordinator = SaveImportCoordinator { result in
        Gow3SaveManager.activeImportCoordinator = nil
        completion(result)
      }
      Gow3SaveManager.activeImportCoordinator = coordinator
      // Important: `asCopy` must be false whenever UTType.folder is included.
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip, .folder], asCopy: false)
      picker.allowsMultipleSelection = false
      picker.delegate = coordinator
      top.present(picker, animated: true)
    }
  }

  // MARK: - Save folder normalization

  private static func directoryChildren(of url: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
  }

  private static func isNumericUserDir(_ url: URL) -> Bool {
    guard isDirectory(url) else { return false }
    let name = url.lastPathComponent
    guard !name.isEmpty, name.allSatisfy(\.isNumber) else { return false }
    return directoryChildren(of: url).contains {
      let child = $0.lastPathComponent
      return child.hasPrefix("CUSA") || child.hasSuffix(".memory")
    }
  }

  private static func locateSavedataSource(in root: URL, depth: Int = 0) -> (url: URL, wrapIntoUserCusa: Bool)? {
    let name = root.lastPathComponent
    if name == "savedata" && treeStats(at: root).fileCount > 0 {
      return (root, false)
    }
    let children = directoryChildren(of: root)
    if let explicit = children.first(where: { isDirectory($0) && $0.lastPathComponent == "savedata" }),
       treeStats(at: explicit).fileCount > 0 {
      return (explicit, false)
    }
    if children.contains(where: isNumericUserDir) {
      return (root, false)
    }
    if name.hasPrefix("CUSA") && treeStats(at: root).fileCount > 0 {
      return (root, true)
    }
    if children.contains(where: { isDirectory($0) && ($0.lastPathComponent.hasPrefix("CUSA") || $0.lastPathComponent.hasSuffix(".memory")) }) {
      return (root, true)
    }
    guard depth < 3 else { return nil }
    for child in children where isDirectory(child) {
      if child.lastPathComponent == "__MACOSX" { continue }
      if let found = locateSavedataSource(in: child, depth: depth + 1) {
        return found
      }
    }
    return nil
  }

  fileprivate static func performImport(from pickedURL: URL) throws -> String {
    let fm = FileManager.default
    let workDir = fm.temporaryDirectory.appendingPathComponent("gow3-import-\(UUID().uuidString)", isDirectory: true)
    let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
    let normalizedDir = workDir.appendingPathComponent("normalized", isDirectory: true)
    try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: workDir) }

    let scoped = pickedURL.startAccessingSecurityScopedResource()
    defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

    var coordError: NSError?
    var pickedIsDir = false
    var readError: Error?
    NSFileCoordinator().coordinate(readingItemAt: pickedURL, options: .withoutChanges, error: &coordError) { url in
      var dirFlag: ObjCBool = false
      if fm.fileExists(atPath: url.path, isDirectory: &dirFlag), dirFlag.boolValue {
        pickedIsDir = true
        do {
          try fm.copyItem(at: url, to: extractDir.appendingPathComponent(url.lastPathComponent, isDirectory: true))
        } catch {
          readError = error
        }
      } else {
        do {
          let archiveData = try Data(contentsOf: url)
          try extractZipArchive(archiveData, to: extractDir)
        } catch {
          readError = error
        }
      }
    }
    if let coordError { throw coordError }
    if let readError { throw readError }

    let searchRoot = pickedIsDir ? extractDir.appendingPathComponent(pickedURL.lastPathComponent, isDirectory: true) : extractDir
    guard let match = locateSavedataSource(in: searchRoot) else {
      throw Gow3SaveError.message("No valid GoW3 save folder (savedata / user id / CUSA*) found.")
    }
    if match.wrapIntoUserCusa {
      try fm.createDirectory(at: normalizedDir, withIntermediateDirectories: true)
      let userDir = normalizedDir.appendingPathComponent("1", isDirectory: true)
      if match.url.lastPathComponent.hasPrefix("CUSA") {
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        try fm.copyItem(at: match.url, to: userDir.appendingPathComponent(match.url.lastPathComponent, isDirectory: true))
      } else {
        try fm.copyItem(at: match.url, to: userDir)
      }
      return try replaceSavedata(withNormalizedSavesDir: normalizedDir, safetyPrefix: "pre-import")
    }
    return try replaceSavedata(withNormalizedSavesDir: match.url, safetyPrefix: "pre-import")
  }

  // MARK: - Minimal PKZIP writer & reader

  private struct ZipCentralRecord {
    var nameData: Data
    var crc32: UInt32
    var size: UInt32
    var localOffset: UInt32
  }

  private static func writeZipArchive(of dir: URL, rootPrefix: String, to outputURL: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: outputURL.path) {
      try fm.removeItem(at: outputURL)
    }
    guard fm.createFile(atPath: outputURL.path, contents: nil) else {
      throw Gow3SaveError.message("Cannot create temporary export archive.")
    }
    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }

    guard let enumerator = fm.enumerator(
      at: dir,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      throw Gow3SaveError.message("Cannot enumerate savedata directory.")
    }

    let resolvedBase = dir.resolvingSymlinksInPath().standardizedFileURL.path
    let basePrefix = resolvedBase.hasSuffix("/") ? resolvedBase : resolvedBase + "/"
    var files: [(url: URL, rel: String)] = []
    for case let fileURL as URL in enumerator {
      guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
            vals.isRegularFile == true else { continue }
      let fullPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
      guard fullPath.hasPrefix(basePrefix) else { continue }
      let rel = String(fullPath.dropFirst(basePrefix.count))
      guard !rel.isEmpty else { continue }
      files.append((fileURL, "\(rootPrefix)/\(rel)"))
    }
    guard !files.isEmpty else {
      throw Gow3SaveError.message("No savedata files to export.")
    }
    guard files.count <= Int(UInt16.max) else {
      throw Gow3SaveError.message("Too many files for ZIP archive.")
    }
    files.sort { $0.rel < $1.rel }

    var records: [ZipCentralRecord] = []
    var offset: UInt64 = 0

    for item in files {
      let payload = try Data(contentsOf: item.url)
      guard payload.count <= Int(UInt32.max), let nameData = item.rel.data(using: .utf8), nameData.count <= Int(UInt16.max) else {
        throw Gow3SaveError.message("Save file too large or invalid path for ZIP archive.")
      }
      guard offset <= UInt64(UInt32.max) else {
        throw Gow3SaveError.message("Save archive exceeds 4 GiB ZIP32 limit.")
      }
      let crc = CRC32.compute(payload)
      let size = UInt32(payload.count)
      let localOffset = UInt32(offset)

      var localHeader = Data(capacity: 30 + nameData.count)
      localHeader.appendLE32(0x0403_4b50)
      localHeader.appendLE16(20)     // version needed
      localHeader.appendLE16(0x0800) // UTF-8 flag
      localHeader.appendLE16(0)      // method: stored
      localHeader.appendLE16(0)      // mod time
      localHeader.appendLE16(0x5421) // mod date
      localHeader.appendLE32(crc)
      localHeader.appendLE32(size)
      localHeader.appendLE32(size)
      localHeader.appendLE16(UInt16(nameData.count))
      localHeader.appendLE16(0)      // extra len
      localHeader.append(nameData)

      try handle.write(contentsOf: localHeader)
      try handle.write(contentsOf: payload)
      offset += UInt64(localHeader.count) + UInt64(payload.count)
      records.append(ZipCentralRecord(nameData: nameData, crc32: crc, size: size, localOffset: localOffset))
    }

    guard offset <= UInt64(UInt32.max) else {
      throw Gow3SaveError.message("Save archive exceeds 4 GiB ZIP32 limit.")
    }
    let cdOffset = UInt32(offset)
    var centralDir = Data()
    for rec in records {
      centralDir.appendLE32(0x0201_4b50)
      centralDir.appendLE16(0x031e) // version made by: Unix
      centralDir.appendLE16(20)
      centralDir.appendLE16(0x0800) // UTF-8
      centralDir.appendLE16(0)      // stored
      centralDir.appendLE16(0)
      centralDir.appendLE16(0x5421)
      centralDir.appendLE32(rec.crc32)
      centralDir.appendLE32(rec.size)
      centralDir.appendLE32(rec.size)
      centralDir.appendLE16(UInt16(rec.nameData.count))
      centralDir.appendLE16(0)
      centralDir.appendLE16(0)
      centralDir.appendLE16(0)
      centralDir.appendLE16(0)
      centralDir.appendLE32(0)
      centralDir.appendLE32(rec.localOffset)
      centralDir.append(rec.nameData)
    }

    var eocd = Data(capacity: 22)
    eocd.appendLE32(0x0605_4b50)
    eocd.appendLE16(0)
    eocd.appendLE16(0)
    eocd.appendLE16(UInt16(records.count))
    eocd.appendLE16(UInt16(records.count))
    eocd.appendLE32(UInt32(centralDir.count))
    eocd.appendLE32(cdOffset)
    eocd.appendLE16(0)

    try handle.write(contentsOf: centralDir)
    try handle.write(contentsOf: eocd)
  }

  private static func extractZipArchive(_ archive: Data, to destDir: URL) throws {
    guard archive.count >= 22 else {
      throw Gow3SaveError.message("File is not a valid ZIP archive.")
    }
    let minOffset = max(0, archive.count - 65535 - 22)
    var eocdOffset: Int?
    for pos in stride(from: archive.count - 22, through: minOffset, by: -1) {
      if archive.u32(pos) == 0x0605_4b50 {
        let commentLen = Int(archive.u16(pos + 20))
        if pos + 22 + commentLen == archive.count {
          eocdOffset = pos
          break
        }
      }
    }
    guard let eocd = eocdOffset else {
      throw Gow3SaveError.message("Invalid ZIP archive (missing End of Central Directory).")
    }
    let totalEntries = Int(archive.u16(eocd + 10))
    let cdSize = Int(archive.u32(eocd + 12))
    let cdOffset = Int(archive.u32(eocd + 16))
    guard totalEntries < 0xffff, cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= eocd else {
      throw Gow3SaveError.message("Unsupported or corrupted ZIP directory.")
    }

    let fm = FileManager.default
    var cursor = cdOffset
    for _ in 0..<totalEntries {
      guard cursor + 46 <= cdOffset + cdSize, archive.u32(cursor) == 0x0201_4b50 else {
        throw Gow3SaveError.message("Corrupted ZIP central directory entry.")
      }
      let flags = archive.u16(cursor + 8)
      let method = archive.u16(cursor + 10)
      let crc = archive.u32(cursor + 16)
      let compSize = Int(archive.u32(cursor + 20))
      let uncompSize = Int(archive.u32(cursor + 24))
      let nameLen = Int(archive.u16(cursor + 28))
      let extraLen = Int(archive.u16(cursor + 30))
      let commentLen = Int(archive.u16(cursor + 32))
      let localOffset = Int(archive.u32(cursor + 42))
      let entryEnd = cursor + 46 + nameLen + extraLen + commentLen
      guard entryEnd <= cdOffset + cdSize else {
        throw Gow3SaveError.message("Truncated ZIP central directory entry.")
      }
      let rawName = String(decoding: archive[(cursor + 46)..<(cursor + 46 + nameLen)], as: UTF8.self)
        .replacingOccurrences(of: "\\", with: "/")
      cursor = entryEnd

      if (flags & 0x0001) != 0 {
        throw Gow3SaveError.message("Encrypted ZIP archives are not supported.")
      }
      if rawName.hasSuffix("/") || rawName.hasPrefix("__MACOSX/") || rawName.hasSuffix("/.DS_Store") || rawName == ".DS_Store" {
        continue
      }
      guard !rawName.hasPrefix("/") else {
        throw Gow3SaveError.message("Unsafe path inside ZIP archive.")
      }
      let parts = rawName.split(separator: "/", omittingEmptySubsequences: false)
      guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw Gow3SaveError.message("Unsafe relative path '\(rawName)' inside ZIP archive.")
      }

      guard localOffset >= 0, localOffset + 30 <= archive.count, archive.u32(localOffset) == 0x0403_4b50 else {
        throw Gow3SaveError.message("Corrupted local ZIP header for '\(rawName)'.")
      }
      let lNameLen = Int(archive.u16(localOffset + 26))
      let lExtraLen = Int(archive.u16(localOffset + 28))
      let dataStart = localOffset + 30 + lNameLen + lExtraLen
      guard dataStart + compSize <= archive.count else {
        throw Gow3SaveError.message("Truncated file data for '\(rawName)' in ZIP archive.")
      }

      let payload: Data
      if method == 0 {
        guard compSize == uncompSize else {
          throw Gow3SaveError.message("Size mismatch on stored entry '\(rawName)'.")
        }
        payload = Data(archive[dataStart..<(dataStart + uncompSize)])
      } else if method == 8 {
        if uncompSize == 0 {
          payload = Data()
        } else {
          guard let decoded = inflateRawDeflate(archive, start: dataStart, compSize: compSize, uncompSize: uncompSize) else {
            throw Gow3SaveError.message("Failed to decompress '\(rawName)' from ZIP archive.")
          }
          payload = decoded
        }
      } else {
        throw Gow3SaveError.message("Unsupported ZIP compression method (\(method)) for '\(rawName)'.")
      }

      guard CRC32.compute(payload) == crc else {
        throw Gow3SaveError.message("CRC check failed for '\(rawName)' in ZIP archive.")
      }
      let target = parts.reduce(destDir) { $0.appendingPathComponent(String($1), isDirectory: false) }
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try payload.write(to: target, options: .atomic)
    }
  }

  private static func inflateRawDeflate(_ archive: Data, start: Int, compSize: Int, uncompSize: Int) -> Data? {
    func tryDecode(offset: Int, length: Int) -> Data? {
      guard length > 0, offset + length <= archive.count else { return nil }
      var out = Data(count: uncompSize)
      let decodedCount: Int = out.withUnsafeMutableBytes { dstRaw in
        archive.withUnsafeBytes { srcRaw in
          guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                let src = srcRaw.baseAddress?.advanced(by: offset).assumingMemoryBound(to: UInt8.self) else {
            return 0
          }
          return compression_decode_buffer(dst, uncompSize, src, length, nil, COMPRESSION_ZLIB)
        }
      }
      return decodedCount == uncompSize ? out : nil
    }
    if let direct = tryDecode(offset: start, length: compSize) {
      return direct
    }
    if compSize > 6 && archive[start] == 0x78 {
      return tryDecode(offset: start + 2, length: compSize - 6)
    }
    return nil
  }
}

private final class SaveImportCoordinator: NSObject, UIDocumentPickerDelegate {
  private var onDone: ((Result<String, Error>) -> Void)?

  init(onDone: @escaping (Result<String, Error>) -> Void) {
    self.onDone = onDone
  }

  private func finish(_ result: Result<String, Error>) {
    guard let callback = onDone else { return }
    onDone = nil
    callback(result)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      finish(.failure(Gow3SaveError.message("No file or folder selected.")))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let message = try Gow3SaveManager.performImport(from: url)
        DispatchQueue.main.async { self.finish(.success(message)) }
      } catch {
        DispatchQueue.main.async { self.finish(.failure(error)) }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(.success("Import cancelled."))
  }
}
