import Foundation

/// Only one-way, domain-separated SHA-256 evidence is durable. The extra English
/// and source-independent digests preserve the existing same-English conflict and
/// optional-origin rules without storing any phrase content.
struct PhraseSafetyEntry: Codable, Equatable, Sendable {
    let accountScopeDigest: String
    let vocabularyDigest: String
    let phraseIdentityDigest: String
    let sourceIndependentPhraseDigest: String
    let englishDigest: String
    let providerPhraseIDDigest: String
    let createdAt: Date

    static func digest(_ domain: String, _ values: [String]) throws -> String {
        try ConfirmationBinding.digest(["domain": "phrase-safety-v1/" + domain, "values": values])
    }

    init(record: PhraseRecord, accountFingerprint: String, vocabularyID: String, createdAt: Date,
         approvedEnglish: String? = nil) throws {
        // Hash the approved spelling after semantic response proof: an NFC/NFD
        // provider echo must not lose protection for that same input on restart.
        // No Unicode normalization, stored field, or legacy migration is added.
        if let approvedEnglish {
            guard PhraseEnglishIdentity.equivalent(record.phrase, approvedEnglish) else {
                throw CompanionError.phraseJournalUnavailable
            }
        }
        // New evidence must also suppress the reverse/mixed-apostrophe response
        // after restart. Raw+canonical lookup alone cannot recover a curly hash
        // from a straight expected string. Existing v1 entries stay untouched.
        let english = PhraseEnglishIdentity.canonical(approvedEnglish ?? record.phrase)
        accountScopeDigest = try Self.digest("account", [accountFingerprint])
        vocabularyDigest = try Self.digest("vocabulary", [vocabularyID])
        phraseIdentityDigest = try Self.digest("phrase", [english, record.interpretation, record.origin])
        sourceIndependentPhraseDigest = try Self.digest("phrase-no-source", [english, record.interpretation])
        englishDigest = try Self.digest("english", [english])
        providerPhraseIDDigest = try Self.digest("provider-id", [record.id])
        self.createdAt = createdAt
    }

    func matchesEnglish(_ english: String) throws -> Bool {
        try PhraseEnglishIdentity.journalCandidates(english).contains {
            englishDigest == (try Self.digest("english", [$0]))
        }
    }

    func matches(_ entry: PhraseBatchEntry) throws -> Bool {
        try PhraseEnglishIdentity.journalCandidates(entry.english).contains { english in
            if let source = entry.source {
                return phraseIdentityDigest == (try Self.digest("phrase", [english, entry.chinese, source]))
            }
            return sourceIndependentPhraseDigest == (try Self.digest("phrase-no-source", [english, entry.chinese]))
        }
    }

    var isValid: Bool {
        [accountScopeDigest, vocabularyDigest, phraseIdentityDigest,
         sourceIndependentPhraseDigest, englishDigest, providerPhraseIDDigest].allSatisfy {
            $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        } && createdAt.timeIntervalSince1970.isFinite
    }
}

protocol PhraseSafetyJournalStore {
    func load() throws -> [PhraseSafetyEntry]
    func save(_ entries: [PhraseSafetyEntry]) throws
}

/// One atomic support file, independent of clearable History and of Keychain.
final class FilePhraseSafetyJournalStore: PhraseSafetyJournalStore {
    private struct Archive: Codable {
        let schemaVersion: Int
        let entries: [PhraseSafetyEntry]
    }

    private let applicationSupportDirectory: URL?

    init(applicationSupportDirectory: URL? = nil) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    private func fileURL(createDirectory: Bool) throws -> URL {
        let support = try applicationSupportDirectory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: createDirectory
        )
        let directory = support.appendingPathComponent("com.davidqyc.momoMoreEfficient", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
        }
        return directory.appendingPathComponent("phrase-safety-v1.json")
    }

    func load() throws -> [PhraseSafetyEntry] {
        let url = try fileURL(createDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Only real ENOENT is an empty first-use journal. Permission and I/O
            // errors must never be mistaken for absence via fileExists().
            return []
        }
        guard data.count <= 4_194_304 else { throw CompanionError.phraseJournalUnavailable }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.schemaVersion == 1 else { throw CompanionError.phraseJournalUnavailable }
        try PhraseSafetyJournal.validate(archive.entries)
        return archive.entries
    }

    func save(_ entries: [PhraseSafetyEntry]) throws {
        try PhraseSafetyJournal.validate(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(schemaVersion: 1, entries: entries))
        guard data.count <= 4_194_304 else { throw CompanionError.phraseJournalUnavailable }
        let url = try fileURL(createDirectory: true)
        try data.write(to: url, options: .atomic)
        excludeFromBackup(url)
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// The production app shares one instance, including the post-save-failure latch,
/// for the process lifetime. It has no reset/clear API. No asynchronous background
/// work, timers, remote requests or second executor live here.
final class PhraseSafetyJournal: @unchecked Sendable {
    static let shared = PhraseSafetyJournal(store: FilePhraseSafetyJournalStore())
    private let store: PhraseSafetyJournalStore
    private let lock = NSLock()
    private var protectionFailed = false

    init(store: PhraseSafetyJournalStore) { self.store = store }

    static func validate(_ entries: [PhraseSafetyEntry]) throws {
        var seen = Set<String>()
        guard entries.allSatisfy({ entry in
            entry.isValid && seen.insert(entry.accountScopeDigest + entry.vocabularyDigest + entry.providerPhraseIDDigest).inserted
        }) else { throw CompanionError.phraseJournalUnavailable }
    }

    private func loaded() throws -> [PhraseSafetyEntry] {
        guard !protectionFailed else { throw CompanionError.phraseJournalProtectionFailed }
        do {
            let entries = try store.load()
            try Self.validate(entries)
            return entries
        } catch { throw CompanionError.phraseJournalUnavailable }
    }

    /// Read + atomic replacement of the unchanged archive tests the actual write
    /// path, rather than trusting a permissions bit. Called before approval and
    /// again before dispatch. It does not assert that later disk writes cannot fail.
    func prepareForCreate() throws {
        lock.lock()
        defer { lock.unlock() }
        let entries = try loaded()
        do { try store.save(entries) }
        catch { throw CompanionError.phraseJournalUnavailable }
    }

    func recordCreated(_ record: PhraseRecord, accountFingerprint: String, vocabularyID: String,
                       approvedEnglish: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard isSafeIdentifier(record.id), record.status == CompanionConstants.status else {
                throw CompanionError.phraseJournalUnavailable
            }
            let entry = try PhraseSafetyEntry(record: record, accountFingerprint: accountFingerprint,
                                              vocabularyID: vocabularyID, createdAt: Date(), approvedEnglish: approvedEnglish)
            var entries = try loaded()
            if let existing = entries.first(where: {
                $0.accountScopeDigest == entry.accountScopeDigest && $0.vocabularyDigest == entry.vocabularyDigest
                    && $0.providerPhraseIDDigest == entry.providerPhraseIDDigest
            }) {
                let rawIdentity = try PhraseSafetyEntry.digest("phrase", [record.phrase, record.interpretation, record.origin])
                guard existing.phraseIdentityDigest == entry.phraseIdentityDigest
                        || existing.phraseIdentityDigest == rawIdentity else {
                    throw CompanionError.phraseJournalUnavailable
                }
            } else { entries.append(entry) }
            try store.save(entries)
        } catch {
            protectionFailed = true
            throw CompanionError.phraseJournalProtectionFailed
        }
    }

    /// Any visibly present ID, including a DELETED tombstone, resolves that
    /// specific pending resource. A list miss never removes evidence. Failed
    /// retirement leaves the file conservative while THIS read excludes visible
    /// IDs from the calculation, so they cannot be counted twice.
    func pending(accountFingerprint: String, vocabularyID: String, visible: [PhraseRecord]) throws -> [PhraseSafetyEntry] {
        lock.lock()
        defer { lock.unlock() }
        let entries = try loaded()
        let account = try PhraseSafetyEntry.digest("account", [accountFingerprint])
        let vocabulary = try PhraseSafetyEntry.digest("vocabulary", [vocabularyID])
        let ids = try Set(visible.map { try PhraseSafetyEntry.digest("provider-id", [$0.id]) })
        let retained = entries.filter {
            !($0.accountScopeDigest == account && $0.vocabularyDigest == vocabulary && ids.contains($0.providerPhraseIDDigest))
        }
        if retained.count != entries.count { try? store.save(retained) }
        return retained.filter { $0.accountScopeDigest == account && $0.vocabularyDigest == vocabulary }
    }
}
