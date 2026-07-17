import Foundation

struct BexData: Codable, Equatable, Sendable {
  let schemaVersion: Int
  var profiles: [Profile]
  var history: [HistoryEntry]

  static let empty = BexData(schemaVersion: 1, profiles: [], history: [])
}

extension Notification.Name {
  static let bexHistoryDidChange = Notification.Name("com.bex.desktop.historyDidChange")
}

actor BexDataStore {
  static let schemaVersion = 1
  static let historyLimit = 500
  static let defaultFileURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Bex", isDirectory: true)
    .appendingPathComponent("data.json", isDirectory: false)

  private static let corruptMessage =
    "Bex could not read its local data. A backup was saved in Application Support."
  private static let newerSchemaMessage =
    "This Bex data was created by a newer version."

  private let fileURL: URL
  private let fileManager: FileManager
  private let replaceExistingItem: @Sendable (FileManager, URL, URL) throws -> Void
  private var cachedData: BexData?
  private var mutationsDisabled = false
  private var pendingLoadError: BexError?

  init(
    fileURL: URL = BexDataStore.defaultFileURL,
    fileManager: FileManager = .default,
    replaceExistingItem: @escaping @Sendable (FileManager, URL, URL) throws -> Void = {
      fileManager,
      originalURL,
      replacementURL in
      _ = try fileManager.replaceItemAt(originalURL, withItemAt: replacementURL)
    }
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.replaceExistingItem = replaceExistingItem
  }

  func loadProfiles() throws -> [Profile] {
    try loadIfNeeded()
    try surfacePendingLoadError()
    return cachedData?.profiles ?? []
  }

  func saveProfile(_ profile: Profile) throws {
    var data = try dataForMutation()
    if let index = data.profiles.firstIndex(where: { $0.id == profile.id }) {
      data.profiles[index] = profile
    } else {
      data.profiles.append(profile)
    }
    try persist(data)
  }

  func deleteProfile(id: UUID) throws {
    var data = try dataForMutation()
    data.profiles.removeAll { $0.id == id }
    try persist(data)
  }

  func loadHistory() throws -> [HistoryEntry] {
    try loadIfNeeded()
    try surfacePendingLoadError()
    return cachedData?.history ?? []
  }

  func appendHistory(_ entry: HistoryEntry) throws {
    var data = try dataForMutation()
    data.history.removeAll { $0.id == entry.id }
    data.history.insert(entry, at: 0)
    if data.history.count > Self.historyLimit {
      data.history.removeLast(data.history.count - Self.historyLimit)
    }
    try persist(data)
    NotificationCenter.default.post(name: .bexHistoryDidChange, object: nil)
  }

  func updateHistory(id: UUID, corrected: String, explanation: String) throws {
    var data = try dataForMutation()
    guard let index = data.history.firstIndex(where: { $0.id == id }) else {
      return
    }
    data.history[index].corrected = corrected
    data.history[index].explanation = explanation
    try persist(data)
    NotificationCenter.default.post(name: .bexHistoryDidChange, object: nil)
  }

  func deleteHistory(id: UUID) throws {
    var data = try dataForMutation()
    data.history.removeAll { $0.id == id }
    try persist(data)
    NotificationCenter.default.post(name: .bexHistoryDidChange, object: nil)
  }

  func clearHistory() throws {
    var data = try dataForMutation()
    data.history.removeAll(keepingCapacity: false)
    try persist(data)
    NotificationCenter.default.post(name: .bexHistoryDidChange, object: nil)
  }

  private func dataForMutation() throws -> BexData {
    try loadIfNeeded()
    try surfacePendingLoadError()
    guard !mutationsDisabled else {
      throw BexError.storageFailure(Self.newerSchemaMessage)
    }
    return cachedData ?? .empty
  }

  private func loadIfNeeded() throws {
    guard cachedData == nil else { return }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      cachedData = .empty
      return
    }

    do {
      let encoded = try Data(contentsOf: fileURL)
      let decoded = try JSONDecoder().decode(BexData.self, from: encoded)
      if decoded.schemaVersion > Self.schemaVersion {
        cachedData = decoded
        mutationsDisabled = true
        pendingLoadError = .storageFailure(Self.newerSchemaMessage)
      } else {
        cachedData = BexData(
          schemaVersion: Self.schemaVersion,
          profiles: decoded.profiles,
          history: Array(decoded.history.prefix(Self.historyLimit))
        )
      }
    } catch let error as BexError {
      throw error
    } catch {
      do {
        try backUpCorruptFile()
        cachedData = .empty
        pendingLoadError = .storageFailure(Self.corruptMessage)
      } catch {
        throw BexError.storageFailure("Bex could not preserve its unreadable local data.")
      }
    }
  }

  private func surfacePendingLoadError() throws {
    guard let error = pendingLoadError else { return }
    pendingLoadError = nil
    throw error
  }

  private func backUpCorruptFile() throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    let directory = fileURL.deletingLastPathComponent()
    var backupURL = directory.appendingPathComponent("data.corrupt-\(stamp).json")
    var suffix = 1
    while fileManager.fileExists(atPath: backupURL.path) {
      backupURL = directory.appendingPathComponent("data.corrupt-\(stamp)-\(suffix).json")
      suffix += 1
    }
    try fileManager.moveItem(at: fileURL, to: backupURL)
  }

  private func persist(_ data: BexData) throws {
    let directory = fileURL.deletingLastPathComponent()
    let temporaryURL = directory.appendingPathComponent(".data-\(UUID().uuidString).tmp")

    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let encoded = try encoder.encode(data)
      try encoded.write(to: temporaryURL, options: .withoutOverwriting)

      if fileManager.fileExists(atPath: fileURL.path) {
        try replaceExistingItem(fileManager, fileURL, temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: fileURL)
      }
      cachedData = data
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      if let bexError = error as? BexError {
        throw bexError
      }
      throw BexError.storageFailure("Bex could not save its local data.")
    }
  }
}
