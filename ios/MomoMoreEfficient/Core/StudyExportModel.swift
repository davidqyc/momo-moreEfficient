import Foundation

// MARK: - Provider schemas (#155, closed)

/// The documented `StudyResponse` vocabulary, including the proto-derived
/// `STUDY_RESPONSE_UNSPECIFIED` sentinel from the current official
/// `memo-api-cli/src/types/study_model.ts`. An unknown provider value outside
/// this closed set is a decode rejection, never a guessed local meaning.
enum StudyResponse: String, Equatable, Sendable {
    case unspecified = "STUDY_RESPONSE_UNSPECIFIED"
    case familiar = "FAMILIAR"
    case vague = "VAGUE"
    case forget = "FORGET"
    case wellFamiliar = "WELL_FAMILIAR"
    case cancelWellFamiliar = "CANCEL_WELL_FAMILIAR"
}

/// The documented record tag set (`StudyRecord.tags`) — an array whose
/// elements come from the proto-derived enum, including the neutral
/// `STUDY_RECORD_TAG_UNSPECIFIED` sentinel.
enum StudyRecordTag: String, Equatable, Sendable {
    case unspecified = "STUDY_RECORD_TAG_UNSPECIFIED"
    case sticking = "STICKING"
    case wellFamiliar = "WELL_FAMILIAR"
}

struct StudyProgress: Equatable, Sendable {
    let finished: Int
    let total: Int
    let studyTimeMilliseconds: Int
}

/// One `get_today_items` entry, in provider study order.
struct StudyTodayItem: Equatable, Sendable {
    let vocabularyID: String
    let spelling: String
    let order: Int
    let firstResponse: StudyResponse?
    let isNew: Bool
    let isFinished: Bool
}

/// One `query_study_records` row. Only the fields a preset consumes are
/// modelled; nothing is synthesised for the rest.
///
/// `addDate` is optional because the current proto-derived official type
/// (`study_model.ts`, sourced from `study_model.proto`) declares
/// `add_date?: string`, and the presets that do not classify by add date must
/// not fail on its absence. `今天新添加` is the preset that needs the
/// classification, and it fail-closes on `nil` itself.
struct StudyRecord: Equatable, Sendable {
    let vocabularyID: String
    let spelling: String
    let addDate: Date?
    let nextStudyDate: Date?
    let studyCount: Int
    let tags: [StudyRecordTag]
}

/// One `query_study_records` page. `count` carries the expected total on an
/// `as_count` call and the documented 0 on a data page.
struct StudyRecordsPage: Equatable, Sendable {
    let records: [StudyRecord]
    let count: Int
}

// MARK: - Export results

/// Whether a produced word list may truthfully be presented as complete.
///
/// Every non-`complete` case still yields a copyable list — the honest label
/// travels with it. What is never allowed is a silent truncation presented as
/// the whole truth.
enum StudyExportCompleteness: Equatable, Sendable {
    case complete
    /// The provider returned exactly the documented single-call maximum
    /// (1000) and nothing else could prove that nothing was left over.
    case cappedAtSingleCallLimit
    /// 今日进度 reports more finished words than the today-items read returned.
    case mismatchedWithProgress(finished: Int, read: Int)
}

/// The outcome of one export run: the spellings, in deterministic
/// first-seen/provider order, plus the completeness truth.
struct StudyExportOutcome: Equatable, Sendable {
    let words: [String]
    let completeness: StudyExportCompleteness
}

/// Read failures that are completeness facts, not transport failures.
enum StudyExportError: Error, Equatable {
    /// The provider's own count disagrees with what the sliding windows yielded.
    case recordCountMismatch(expected: Int, read: Int)
    /// A full page re-returned only already-seen records or repeated the
    /// boundary, so no documented forward step can prove completeness.
    case paginationNotAdvancing
    /// The page's last record has no usable `next_study_date` to slide from.
    case paginationBoundaryUnavailable
    /// 今天新添加 cannot classify at least one otherwise-valid record because
    /// its `add_date` is absent; exporting it as "today added" would be a
    /// guess, so this preset alone fails closed.
    case addDateUnavailable
}

// MARK: - Presets

/// The frozen v1 preset set. No query language, no arbitrary dates.
enum StudyExportPreset: Hashable, Sendable {
    case todayLearned
    case todayAdded
    case todayNew
    case todayForgotten
    case todayVague
    case sticking
    case wellFamiliar
    case reviewWithin(days: Int)
    case allWords

    /// The fixed review-window choices. Deliberately not user-editable.
    static let reviewDayChoices = [1, 3, 7, 30]

    static let all: [StudyExportPreset] = [
        .todayLearned, .todayAdded, .todayNew, .todayForgotten, .todayVague,
        .sticking, .wellFamiliar, .reviewWithin(days: 1), .allWords,
    ]

    var title: String {
        switch self {
        case .todayLearned: return "今天已学"
        case .todayAdded: return "今天新添加"
        case .todayNew: return "今天新学"
        case .todayForgotten: return "今天忘记"
        case .todayVague: return "今天模糊"
        case .sticking: return "顽固词"
        case .wellFamiliar: return "熟知词"
        case let .reviewWithin(days): return "\(days) 天内复习"
        case .allWords: return "全部学习词"
        }
    }

    /// Stable, non-sensitive identifier for diagnostics.
    var caseName: String {
        switch self {
        case .todayLearned: return "todayLearned"
        case .todayAdded: return "todayAdded"
        case .todayNew: return "todayNew"
        case .todayForgotten: return "todayForgotten"
        case .todayVague: return "todayVague"
        case .sticking: return "sticking"
        case .wellFamiliar: return "wellFamiliar"
        case let .reviewWithin(days): return "reviewWithin(\(days))"
        case .allWords: return "allWords"
        }
    }

    var subtitle: String {
        switch self {
        case .todayLearned: return "今天已完成的词，按墨墨学习顺序"
        case .todayAdded: return "学习记录里今天新加入的词"
        case .todayNew: return "今天第一次出现的生词"
        case .todayForgotten: return "今天第一次反应为「忘记」的词"
        case .todayVague: return "今天第一次反应为「模糊」的词"
        case .sticking: return "被墨墨标记为顽固的词"
        case .wellFamiliar: return "被墨墨标记为熟知的词"
        case let .reviewWithin(days): return "接下来 \(days) 天内要复习的词"
        case .allWords: return "学习计划里的全部词"
        }
    }
}

// MARK: - Date wire format

/// The Study API's ISO 8601 date parsing: offset-carrying forms first, then a
/// fractional-seconds variant; a bare `yyyy-MM-dd` value is interpreted on the
/// documented Beijing study calendar (midnight +08:00). Anything else is
/// unparsable and must fail closed upstream.
enum StudyDateParsing {
    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: trimmed) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = StudyExportSemantics.studyTimeZone
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: trimmed)
    }
}

// MARK: - Pure semantics

/// The deterministic preset derivations, kept network-free so the timezone
/// rules and filters are testable without a transport.
enum StudyExportSemantics {

    /// Maimemo's study calendar day is Beijing time (UTC+8, no DST).
    static let studyTimeZone = TimeZone(secondsFromGMT: 8 * 3600)!

    /// The half-open Beijing study day `[start, next start)` containing `now`.
    static func beijingStudyDay(containing now: Date) -> Range<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = studyTimeZone
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return start..<end
    }

    /// 今天新添加: the record's `add_date` falls on today's Beijing study
    /// day. A record whose `add_date` is absent cannot be classified by this
    /// pure function; `今天新添加` fails closed on such records before ever
    /// filtering, so `nil` never reaches a silent "not today" answer here.
    static func isAddedToday(_ record: StudyRecord, now: Date) -> Bool {
        guard let addDate = record.addDate else { return false }
        return beijingStudyDay(containing: now).contains(addDate)
    }

    /// 今天忘记 / 今天模糊: first response of today's *completed* items.
    /// Deliberately `first_response`, never `StudyRecord.last_response`.
    static func isFirstResponse(_ response: StudyResponse, in item: StudyTodayItem) -> Bool {
        item.firstResponse == response
    }

    /// The fixed N-day review window's `next_study_date` upper bound: a rolling
    /// `now + N days`. Words already overdue carry no start bound, so a word
    /// due yesterday is still "due within N days". The bound is expressed in
    /// Beijing time exactly as the official examples do.
    static func reviewWindowEnd(days: Int, now: Date) -> Date {
        now.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    static func beijingISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = studyTimeZone
        return formatter.string(from: date)
    }

    /// Deduplicates by provider `voc_id`, keeping the first-seen order.
    /// Normalised spellings are deliberately *not* a merge key: two provider
    /// identities may share a spelling, and collapsing them would hide a real
    /// word from the export.
    static func dedupedByVocabularyID<T>(_ values: [(id: String, value: T)]) -> [T] {
        var seen = Set<String>()
        return values.compactMap { seen.insert($0.id).inserted ? $0.value : nil }
    }
}
