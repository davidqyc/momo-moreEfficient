import Foundation
import OSLog

/// Whether the #155 on-device diagnostics surface is Owner-visible.
///
/// The Owner's standing rule: a new feature reaching the physical phone for
/// real acceptance carries usable on-device diagnostics until stable. Keep
/// this `true` through #155 real-use stabilization; once the Owner confirms
/// the feature stable, diagnostics may be hidden, reduced or removed by ROI.
enum StudyExportDiagnosticsPolicy {
    static let isOwnerVisible = true
}

/// One sanitized diagnostic event. Only safe values ever reach `text`:
/// timestamps, counts, booleans, preset/route names, enum categories and date
/// boundaries. Spellings, word lists, `voc_id`s, credentials, fingerprints,
/// raw request/response bodies and arbitrary server text must never be
/// formatted into an event.
struct StudyExportDiagnosticEvent: Codable, Equatable, Sendable {
    let at: Date
    /// Short-lived local run correlation id (8 chars of a UUID). Not an
    /// account identity.
    let run: String?
    let text: String
}

/// Error → fixed, sanitized category text for diagnostics. Deliberately never
/// includes provider response text or raw bodies; numbers on
/// record-count facts are counts, not content.
enum StudyExportDiagnosticCategory {
    static func sanitized(_ error: Error) -> String {
        switch error {
        case let error as CompanionError:
            return "companion.\(error.rawValue)"
        case let error as StudyRecordDecodeError:
            // Fixed field-class name only; never any provider value.
            return "studyRecordDecode.\(error.field.rawValue)"
        case let error as StudyExportError:
            switch error {
            case let .recordCountMismatch(expected, read):
                return "studyExport.recordCountMismatch expected=\(expected) read=\(read)"
            case .paginationNotAdvancing:
                return "studyExport.paginationNotAdvancing"
            case .paginationBoundaryUnavailable:
                return "studyExport.paginationBoundaryUnavailable"
            case .addDateUnavailable:
                return "studyExport.addDateUnavailable"
            case let .coverageGap(expected, read, countedThroughFinalDate):
                return "studyExport.coverageGap expected=\(expected) read=\(read)"
                    + " counted_through_final_date=\(countedThroughFinalDate)"
            }
        case is CancellationError:
            return "cancelled"
        default:
            return "unknown"
        }
    }

    static func name(of completeness: StudyExportCompleteness) -> String {
        switch completeness {
        case .complete: return "complete"
        case .cappedAtSingleCallLimit: return "cappedAtSingleCallLimit"
        case .mismatchedWithProgress: return "mismatchedWithProgress"
        case .mismatchedWithRemainingProgress: return "mismatchedWithRemainingProgress"
        }
    }
}

/// The #155 on-device diagnostic trail (Owner standing rule, Issue #155
/// comment 5686449945): a bounded, local-only journal of recent export-run
/// events, mirrored into Apple unified logging, surfaced on the Study Export
/// screen as copyable plain text.
///
/// Deliberately not analytics, remote logging, telemetry, crash reporting, or
/// a portfolio-wide logging framework. One small archive file under the
/// app's own Application Support directory — the same bounded,
/// best-effort, backup-excluded pattern the D-020 phrase safety ledger
/// already established — capped at 300 events / 96 KB, oldest events trimmed
/// first, cleared by the in-app `清除诊断` control.
///
/// Logging failure NEVER changes Study Export behavior or completeness:
/// every persistence step is best-effort, and diagnostics are not business
/// state. The journal survives ordinary relaunch and deliberately survives
/// account replacement/removal because it contains no account identity and
/// no private word data.
final class StudyExportDiagnosticJournal: @unchecked Sendable {
    static let shared = StudyExportDiagnosticJournal(storeURL: defaultStoreURL())

    /// Bounded recent evidence only.
    static let maxEventCount = 300
    static let maxByteCount = 96 * 1024

    private struct Archive: Codable {
        let schemaVersion: Int
        let events: [StudyExportDiagnosticEvent]
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.davidqyc.momoMoreEfficient",
        category: "study-export"
    )

    private let lock = NSLock()
    private var events: [StudyExportDiagnosticEvent]
    private let storeURL: URL?
    private let now: () -> Date

    /// `storeURL == nil` means memory-only (used by tests). A real archive
    /// path makes the journal survive relaunch.
    init(storeURL: URL?, now: @escaping () -> Date = Date.init) {
        self.storeURL = storeURL
        self.now = now
        events = Self.loadEvents(from: storeURL)
    }

    /// Appends one sanitized event, trims to the caps, persists best-effort,
    /// and mirrors the same structural line into the `study-export` OSLog
    /// category. Every step is best-effort; callers never branch on journal
    /// outcomes.
    func log(_ text: String, run: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let event = StudyExportDiagnosticEvent(at: now(), run: run, text: text)
        events.append(event)
        trim()
        persistBestEffort()
        Self.logger.log("\(Self.consoleLine(event), privacy: .public)")
    }

    /// Clears persisted and in-memory evidence.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        events = []
        guard let storeURL else { return }
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// The Owner-copyable plain-text report. Contains only the header facts
    /// and the same sanitized event lines; never private payload.
    func formattedReport(now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        var lines = [
            "小黑鸟伴侣 Study Export Diagnostic v1",
            "app=\(Self.appVersion)",
            "generated_at=\(Self.reportTimestamp(now))",
        ]
        if let lastRun = events.compactMap(\.run).last {
            lines.append("run=\(lastRun)")
        }
        lines.append("---")
        if events.isEmpty {
            lines.append("(no events)")
        } else {
            lines.append(contentsOf: events.map(Self.reportLine))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Implementation

    private func trim() {
        var candidate = events
        while candidate.count > Self.maxEventCount {
            candidate.removeFirst(candidate.count - Self.maxEventCount)
        }
        var encoded = try? Self.encodedArchive(candidate)
        while let data = encoded, data.count > Self.maxByteCount, candidate.count > 1 {
            candidate.removeFirst()
            encoded = try? Self.encodedArchive(candidate)
        }
        events = candidate
    }

    private func persistBestEffort() {
        guard let storeURL,
              let data = try? Self.encodedArchive(events)
        else { return }
        do {
            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
            excludeFromBackup(storeURL)
        } catch {
            // Best effort by contract: a failed diagnostic write is never a
            // Study Export failure and is never surfaced as one.
        }
    }

    private static func encodedArchive(_ events: [StudyExportDiagnosticEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Archive(schemaVersion: 1, events: events))
    }

    private static func loadEvents(from storeURL: URL?) -> [StudyExportDiagnosticEvent] {
        guard let storeURL else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch let error as NSError
        where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        } catch {
            return []
        }
        guard data.count <= maxByteCount * 4 else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data),
              archive.schemaVersion == 1
        else { return [] }
        return archive.events
    }

    /// Production location: the app's own Application Support directory, same
    /// bounded-local-file convention as the D-020 phrase safety ledger.
    private static func defaultStoreURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return support
            .appendingPathComponent("com.davidqyc.momoMoreEfficient", isDirectory: true)
            .appendingPathComponent("study-export-diagnostics-v1.json")
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Formatting (safe fields only)

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private static func reportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: date)
    }

    private static let reportClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func reportLine(_ event: StudyExportDiagnosticEvent) -> String {
        let runPrefix = event.run.map { "\($0) " } ?? ""
        return "\(reportClockFormatter.string(from: event.at)) \(runPrefix)\(event.text)"
    }

    private static func consoleLine(_ event: StudyExportDiagnosticEvent) -> String {
        let runPrefix = event.run.map { " run=\($0)" } ?? ""
        return "study-export \(event.text)\(runPrefix)"
    }
}
