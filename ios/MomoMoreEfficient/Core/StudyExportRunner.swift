import Foundation

/// The provider half of the study word export (#155).
///
/// Deliberately thin, like `QueryReadRunner`: it holds no state and makes no
/// stop/retry decisions. Every request goes through the one authenticated
/// transport and the shared scheduler the root owner's lease handed over, and
/// every sequencing decision is a pure function of what came back.
struct StudyExportRunner {
    let api: MaimemoTransport

    /// Runs one frozen preset to a copyable outcome, or throws a truthful
    /// failure. There is no retry anywhere in this path; a failed preset only
    /// reruns when the user taps it again.
    func run(
        _ preset: StudyExportPreset,
        control: ExecutionControl,
        now: Date
    ) async throws -> StudyExportOutcome {
        switch preset {
        case .todayLearned:
            return try await todayLearned(control: control)
        case .todayNew:
            return try await todayNew(control: control)
        case .todayForgotten:
            return try await todayFiltered(
                firstResponse: .forget, control: control
            )
        case .todayVague:
            return try await todayFiltered(
                firstResponse: .vague, control: control
            )
        case .todayAdded:
            let loaded = try await loadAllRecords(endBoundary: nil, control: control)
            // This preset classifies every safely retrieved record by add
            // date. An absent `add_date` cannot be classified, so exporting
            // "today added" without it would be a guess: fail closed here,
            // and only here — the other record presets need no add date.
            guard !loaded.records.contains(where: { $0.addDate == nil }) else {
                throw StudyExportError.addDateUnavailable
            }
            let records = loaded.records.filter { StudyExportSemantics.isAddedToday($0, now: now) }
            return StudyExportOutcome(words: records.map(\.spelling), completeness: loaded.completeness)
        case .sticking:
            return try await tagged(.sticking, control: control)
        case .wellFamiliar:
            return try await tagged(.wellFamiliar, control: control)
        case let .reviewWithin(days):
            let loaded = try await loadAllRecords(
                endBoundary: StudyExportSemantics.reviewWindowEnd(days: days, now: now),
                control: control
            )
            return StudyExportOutcome(words: loaded.records.map(\.spelling), completeness: loaded.completeness)
        case .allWords:
            let loaded = try await loadAllRecords(endBoundary: nil, control: control)
            return StudyExportOutcome(words: loaded.records.map(\.spelling), completeness: loaded.completeness)
        }
    }

    // MARK: - Today-item presets

    /// The one completed-items read every today preset starts from, together
    /// with the completeness evidence that read produced — so 今天已学,
    /// 今天忘记 and 今天模糊 can never drift apart on that judgment.
    ///
    /// The progress read shares 今天已学's non-blocking semantics: a progress
    /// failure never blocks the item read (a short page proves the items
    /// endpoint's own completeness), but a progress count that *exceeds* the
    /// returned completed items downgrades the result to "may be incomplete".
    private func completedItems(
        control: ExecutionControl
    ) async throws -> (items: [StudyTodayItem], completeness: StudyExportCompleteness) {
        let progress = try? await api.studyProgress(control: control)
        let items = try await fetchTodayItems(isFinished: true, isNew: nil, control: control)
        return (items, todayCompleteness(fetched: items.count, progress: progress))
    }

    /// 今天已学: completed items in provider study order.
    private func todayLearned(control: ExecutionControl) async throws -> StudyExportOutcome {
        let (items, completeness) = try await completedItems(control: control)
        let words = StudyExportSemantics.dedupedByVocabularyID(
            items.map { (id: $0.vocabularyID, value: $0.spelling) }
        )
        return StudyExportOutcome(words: words, completeness: completeness)
    }

    /// 今天新学: new items in provider order. Progress carries no new-word
    /// count, so exactly-1000 stays honestly capped.
    private func todayNew(control: ExecutionControl) async throws -> StudyExportOutcome {
        try await fetchToday(isFinished: nil, isNew: true, progress: nil, control: control)
    }

    /// 今天忘记 / 今天模糊: today's *completed* items, filtered locally by
    /// `first_response`. Never `StudyRecord.last_response`. The filtered list
    /// inherits exactly the completed-items source's completeness — a
    /// mismatched or capped source cannot present a filtered subset as
    /// complete.
    private func todayFiltered(
        firstResponse: StudyResponse,
        control: ExecutionControl
    ) async throws -> StudyExportOutcome {
        let (items, completeness) = try await completedItems(control: control)
        let filtered = items.filter { StudyExportSemantics.isFirstResponse(firstResponse, in: $0) }
        let words = StudyExportSemantics.dedupedByVocabularyID(
            filtered.map { (id: $0.vocabularyID, value: $0.spelling) }
        )
        return StudyExportOutcome(words: words, completeness: completeness)
    }

    private func fetchToday(
        isFinished: Bool?,
        isNew: Bool?,
        progress: StudyProgress?,
        control: ExecutionControl
    ) async throws -> StudyExportOutcome {
        let items = try await fetchTodayItems(isFinished: isFinished, isNew: isNew, control: control)
        let words = StudyExportSemantics.dedupedByVocabularyID(
            items.map { (id: $0.vocabularyID, value: $0.spelling) }
        )
        return StudyExportOutcome(
            words: words,
            completeness: todayCompleteness(fetched: items.count, progress: progress)
        )
    }

    private func fetchTodayItems(
        isFinished: Bool?,
        isNew: Bool?,
        control: ExecutionControl
    ) async throws -> [StudyTodayItem] {
        try await api.studyTodayItems(isFinished: isFinished, isNew: isNew, control: control)
    }

    /// The frozen completeness rule for one today-items read of `fetched`
    /// rows: a short page proves the endpoint's completeness unless the
    /// progress count disagrees; exactly the page maximum is capped unless the
    /// progress count proves equality; a larger progress count always wins
    /// with a truthful mismatch.
    private func todayCompleteness(
        fetched: Int,
        progress: StudyProgress?
    ) -> StudyExportCompleteness {
        if let progress, progress.finished > fetched {
            return .mismatchedWithProgress(finished: progress.finished, read: fetched)
        }
        if fetched >= CompanionConstants.studyPageSize {
            if let progress, progress.finished == fetched {
                return .complete
            }
            return .cappedAtSingleCallLimit
        }
        return .complete
    }

    // MARK: - Record presets

    private func tagged(
        _ tag: StudyRecordTag,
        control: ExecutionControl
    ) async throws -> StudyExportOutcome {
        let loaded = try await loadAllRecords(endBoundary: nil, control: control)
        let records = loaded.records.filter { $0.tags.contains(tag) }
        return StudyExportOutcome(words: records.map(\.spelling), completeness: loaded.completeness)
    }

    /// The bounded, always-terminating full-record loader along the documented
    /// sliding `next_study_date` strategy:
    ///
    /// 1. `as_count` first, for the expected total.
    /// 2. Pages of 1000; records deduplicated by provider `voc_id` in
    ///    first-seen order.
    /// 3. Terminal short page: complete when the collected uniques reach the
    ///    expected total, otherwise a truthful count mismatch.
    /// 4. Full page: slide the window start to the last record's
    ///    `next_study_date`. No usable boundary, a repeated boundary, or a
    ///    page that contributes no new `voc_id` is a completeness failure —
    ///    the documented API cannot prove completeness past that point.
    /// 5. A hard page ceiling derived from the expected total guarantees
    ///    termination even if every other check somehow passed.
    private func loadAllRecords(
        endBoundary: Date?,
        control: ExecutionControl
    ) async throws -> (records: [StudyRecord], completeness: StudyExportCompleteness) {
        let formattedEnd = endBoundary.map { StudyExportSemantics.beijingISO8601($0) }
        let countPage = try await api.studyRecords(
            nextStudyDateStart: nil,
            nextStudyDateEnd: formattedEnd,
            asCount: true,
            control: control
        )
        let expectedTotal = countPage.count
        if expectedTotal == 0 {
            return ([], .complete)
        }

        var seen = Set<String>()
        var collected: [StudyRecord] = []
        var currentBoundary: String?
        var pagesRemaining = expectedTotal + 1

        while true {
            guard !control.isCancellationRequested else { throw CompanionError.cancelled }
            let page = try await api.studyRecords(
                nextStudyDateStart: currentBoundary,
                nextStudyDateEnd: formattedEnd,
                asCount: false,
                control: control
            )
            var newCount = 0
            for record in page.records where seen.insert(record.vocabularyID).inserted {
                collected.append(record)
                newCount += 1
            }
            if collected.count >= expectedTotal {
                return (collected, .complete)
            }
            guard page.records.count == CompanionConstants.studyPageSize else {
                throw StudyExportError.recordCountMismatch(expected: expectedTotal, read: collected.count)
            }
            // Full page: slide, or fail closed. Records without a usable
            // `next_study_date` cannot seed the next window, and the documented
            // API has no other pagination lever.
            guard let last = page.records.last,
                  let lastDate = last.nextStudyDate
            else {
                throw StudyExportError.paginationBoundaryUnavailable
            }
            let nextBoundary = StudyExportSemantics.beijingISO8601(lastDate)
            let boundaryDidNotAdvance = (nextBoundary == currentBoundary)
            currentBoundary = nextBoundary
            guard !boundaryDidNotAdvance, newCount > 0 else {
                throw StudyExportError.paginationNotAdvancing
            }
            pagesRemaining -= 1
            if pagesRemaining < 0 {
                // Unreachable while the checks above hold; kept as the hard
                // termination bound the contract requires.
                throw StudyExportError.paginationNotAdvancing
            }
        }
    }
}
