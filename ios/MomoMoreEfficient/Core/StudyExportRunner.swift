import Foundation

/// The provider half of the study word export (#155).
///
/// Deliberately thin, like `QueryReadRunner`: it holds no state and makes no
/// stop/retry decisions. Every request goes through the one authenticated
/// transport and the shared scheduler the root owner's lease handed over, and
/// every sequencing decision is a pure function of what came back.
///
/// The optional diagnostic journal records only sanitized facts — route
/// starts/ends, row counts, boundaries, mapped error categories, completeness
/// enums — never spellings, word lists, `voc_id`s, credentials or raw
/// payloads. Journal failures cannot affect any outcome: the journal is
/// best-effort by contract.
struct StudyExportRunner {
    let api: MaimemoTransport
    var journal: StudyExportDiagnosticJournal?

    init(api: MaimemoTransport, journal: StudyExportDiagnosticJournal? = nil) {
        self.api = api
        self.journal = journal
    }

    private func log(_ text: String, runID: String) {
        journal?.log(text, run: runID)
    }

    /// Runs one frozen preset to a copyable outcome, or throws a truthful
    /// failure. There is no retry anywhere in this path; a failed preset only
    /// reruns when the user taps it again.
    func run(
        _ preset: StudyExportPreset,
        control: ExecutionControl,
        now: Date,
        runID: String = "run"
    ) async throws -> StudyExportOutcome {
        switch preset {
        case .todayLearned:
            return try await todayLearned(control: control, runID: runID)
        case .todayPending:
            return try await todayPending(control: control, runID: runID)
        case .todayNew:
            return try await todayNew(control: control, runID: runID)
        case .todayForgotten:
            return try await todayFiltered(
                firstResponse: .forget, control: control, runID: runID
            )
        case .todayVague:
            return try await todayFiltered(
                firstResponse: .vague, control: control, runID: runID
            )
        case .todayAdded:
            let loaded = try await loadAllRecords(endBoundary: nil, control: control, runID: runID)
            // This preset classifies every safely retrieved record by add
            // date. An absent `add_date` cannot be classified, so exporting
            // "today added" without it would be a guess: fail closed here,
            // and only here — the other record presets need no add date.
            let missingAddDate = loaded.records.count(where: { $0.addDate == nil })
            guard missingAddDate == 0 else {
                log("added_missing_add_date count=\(missingAddDate)", runID: runID)
                throw StudyExportError.addDateUnavailable
            }
            let records = loaded.records.filter { StudyExportSemantics.isAddedToday($0, now: now) }
            log("today_added count=\(records.count)", runID: runID)
            return StudyExportOutcome(words: records.map(\.spelling), completeness: loaded.completeness)
        case .sticking:
            return try await tagged(.sticking, control: control, runID: runID)
        case .wellFamiliar:
            return try await tagged(.wellFamiliar, control: control, runID: runID)
        case let .reviewWithin(days):
            let loaded = try await loadAllRecords(
                endBoundary: StudyExportSemantics.reviewWindowEnd(days: days, now: now),
                control: control,
                runID: runID
            )
            log("review_window days=\(days) count=\(loaded.records.count)", runID: runID)
            return StudyExportOutcome(words: loaded.records.map(\.spelling), completeness: loaded.completeness)
        case .allWords:
            let loaded = try await loadAllRecords(endBoundary: nil, control: control, runID: runID)
            return StudyExportOutcome(words: loaded.records.map(\.spelling), completeness: loaded.completeness)
        }
    }

    // MARK: - Today-item presets

    /// The shared today-progress read with its sanitized events. A progress
    /// failure is non-blocking for every today preset: it only downgrades the
    /// available completeness evidence.
    private func readProgress(control: ExecutionControl, runID: String) async -> StudyProgress? {
        log("progress_start", runID: runID)
        do {
            let progress = try await api.studyProgress(control: control)
            log("progress_ok finished=\(progress.finished) total=\(progress.total)", runID: runID)
            return progress
        } catch {
            log("progress_error category=\(StudyExportDiagnosticCategory.sanitized(error))", runID: runID)
            return nil
        }
    }

    /// The one completed-items read every today preset starts from, together
    /// with the completeness evidence that read produced — so 今天已学,
    /// 今天忘记 and 今天模糊 can never drift apart on that judgment.
    ///
    /// The progress read shares 今天已学's non-blocking semantics: a progress
    /// failure never blocks the item read (a short page proves the items
    /// endpoint's own completeness), but a progress count that *exceeds* the
    /// returned completed items downgrades the result to "may be incomplete".
    private func completedItems(
        control: ExecutionControl,
        runID: String
    ) async throws -> (items: [StudyTodayItem], completeness: StudyExportCompleteness) {
        let progress = await readProgress(control: control, runID: runID)
        let items = try await fetchTodayItems(isFinished: true, isNew: nil, control: control, runID: runID)
        let completeness = todayCompleteness(fetched: items.count, progress: progress, runID: runID)
        return (items, completeness)
    }

    /// 今天已学: completed items in provider study order.
    private func todayLearned(control: ExecutionControl, runID: String) async throws -> StudyExportOutcome {
        let (items, completeness) = try await completedItems(control: control, runID: runID)
        let words = StudyExportSemantics.dedupedByVocabularyID(
            items.map { (id: $0.vocabularyID, value: $0.spelling) }
        )
        return StudyExportOutcome(words: words, completeness: completeness)
    }

    /// 今日待复习: all of today's unfinished items (`is_finished=false`),
    /// including unfinished review words AND unfinished today's new words —
    /// deliberately no `is_new` filter, so new words are never silently
    /// excluded. Completeness uses remaining semantics (`total - finished`)
    /// when today's progress is usable; an impossible `finished > total` makes
    /// progress unusable for this preset (never a negative count) and falls
    /// back to the page-size rule with a sanitized
    /// `progress_inconsistent` event.
    private func todayPending(control: ExecutionControl, runID: String) async throws -> StudyExportOutcome {
        var progress = await readProgress(control: control, runID: runID)
        if let value = progress, value.finished > value.total {
            log(
                "progress_inconsistent finished=\(value.finished) total=\(value.total)",
                runID: runID
            )
            progress = nil
        }
        let items = try await fetchTodayItems(isFinished: false, isNew: nil, control: control, runID: runID)
        let words = StudyExportSemantics.dedupedByVocabularyID(
            items.map { (id: $0.vocabularyID, value: $0.spelling) }
        )
        let completeness: StudyExportCompleteness
        if let progress {
            let expectedRemaining = progress.total - progress.finished
            completeness = items.count == expectedRemaining
                ? .complete
                : .mismatchedWithRemainingProgress(remaining: expectedRemaining, read: items.count)
        } else {
            completeness = items.count >= CompanionConstants.studyPageSize
                ? .cappedAtSingleCallLimit
                : .complete
        }
        let expectedRemainingDescription: String
        if let progress {
            expectedRemainingDescription = String(progress.total - progress.finished)
        } else {
            expectedRemainingDescription = "nil"
        }
        log(
            "today_pending expected_remaining=\(expectedRemainingDescription)"
                + " fetched=\(items.count)"
                + " completeness=\(StudyExportDiagnosticCategory.name(of: completeness))",
            runID: runID
        )
        return StudyExportOutcome(words: words, completeness: completeness)
    }

    /// 今天新学: new items in provider order. Progress carries no new-word
    /// count, so exactly-1000 stays honestly capped.
    private func todayNew(control: ExecutionControl, runID: String) async throws -> StudyExportOutcome {
        try await fetchToday(isFinished: nil, isNew: true, progress: nil, control: control, runID: runID)
    }

    /// 今天忘记 / 今天模糊: today's *completed* items, filtered locally by
    /// `first_response`. Never `StudyRecord.last_response`. The filtered list
    /// inherits exactly the completed-items source's completeness — a
    /// mismatched or capped source cannot present a filtered subset as
    /// complete.
    private func todayFiltered(
        firstResponse: StudyResponse,
        control: ExecutionControl,
        runID: String
    ) async throws -> StudyExportOutcome {
        let (items, completeness) = try await completedItems(control: control, runID: runID)
        let filtered = items.filter { StudyExportSemantics.isFirstResponse(firstResponse, in: $0) }
        let words = StudyExportSemantics.dedupedByVocabularyID(
            filtered.map { (id: $0.vocabularyID, value: $0.spelling) }
        )
        log("first_response_filter response=\(firstResponse.rawValue) count=\(words.count)", runID: runID)
        return StudyExportOutcome(words: words, completeness: completeness)
    }

    private func fetchToday(
        isFinished: Bool?,
        isNew: Bool?,
        progress: StudyProgress?,
        control: ExecutionControl,
        runID: String
    ) async throws -> StudyExportOutcome {
        let items = try await fetchTodayItems(isFinished: isFinished, isNew: isNew, control: control, runID: runID)
        let words = StudyExportSemantics.dedupedByVocabularyID(
            items.map { (id: $0.vocabularyID, value: $0.spelling) }
        )
        return StudyExportOutcome(
            words: words,
            completeness: todayCompleteness(fetched: items.count, progress: progress, runID: runID)
        )
    }

    private func fetchTodayItems(
        isFinished: Bool?,
        isNew: Bool?,
        control: ExecutionControl,
        runID: String
    ) async throws -> [StudyTodayItem] {
        log(
            "today_items_start is_finished=\(isFinished.map(String.init) ?? "nil")"
                + " is_new=\(isNew.map(String.init) ?? "nil")"
                + " limit=\(CompanionConstants.studyPageSize)",
            runID: runID
        )
        do {
            let items = try await api.studyTodayItems(isFinished: isFinished, isNew: isNew, control: control)
            log("today_items_ok rows=\(items.count)", runID: runID)
            return items
        } catch {
            log("today_items_error category=\(StudyExportDiagnosticCategory.sanitized(error))", runID: runID)
            throw error
        }
    }

    /// The frozen completeness rule for one today-items read of `fetched`
    /// rows: a short page proves the endpoint's completeness unless the
    /// progress count disagrees; exactly the page maximum is capped unless the
    /// progress count proves equality; a larger progress count always wins
    /// with a truthful mismatch.
    private func todayCompleteness(
        fetched: Int,
        progress: StudyProgress?,
        runID: String
    ) -> StudyExportCompleteness {
        let result: StudyExportCompleteness
        if let progress, progress.finished > fetched {
            result = .mismatchedWithProgress(finished: progress.finished, read: fetched)
        } else if fetched >= CompanionConstants.studyPageSize {
            if let progress, progress.finished == fetched {
                result = .complete
            } else {
                result = .cappedAtSingleCallLimit
            }
        } else {
            result = .complete
        }
        log(
            "today_completeness fetched=\(fetched)"
                + " progress_finished=\(progress.map { String($0.finished) } ?? "nil")"
                + " result=\(StudyExportDiagnosticCategory.name(of: result))",
            runID: runID
        )
        return result
    }

    // MARK: - Record presets

    private func tagged(
        _ tag: StudyRecordTag,
        control: ExecutionControl,
        runID: String
    ) async throws -> StudyExportOutcome {
        let loaded = try await loadAllRecords(endBoundary: nil, control: control, runID: runID)
        let records = loaded.records.filter { $0.tags.contains(tag) }
        log("tag_filter tag=\(tag.rawValue) count=\(records.count)", runID: runID)
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
        control: ExecutionControl,
        runID: String
    ) async throws -> (records: [StudyRecord], completeness: StudyExportCompleteness) {
        let formattedEnd = endBoundary.map { StudyExportSemantics.beijingISO8601($0) }
        log("records_count_start end=\(formattedEnd ?? "nil")", runID: runID)
        let countPage: StudyRecordsPage
        do {
            countPage = try await api.studyRecords(
                nextStudyDateStart: nil,
                nextStudyDateEnd: formattedEnd,
                asCount: true,
                control: control
            )
        } catch {
            log("records_count_error category=\(StudyExportDiagnosticCategory.sanitized(error))", runID: runID)
            throw error
        }
        let expectedTotal = countPage.count
        log("records_count_ok expected=\(expectedTotal)", runID: runID)
        if expectedTotal == 0 {
            log("records_done reason=expected_total", runID: runID)
            return ([], .complete)
        }

        var seen = Set<String>()
        var collected: [StudyRecord] = []
        var currentBoundary: String?
        var pagesRemaining = expectedTotal + 1
        var pageIndex = 0
        // The final successfully decoded record's actual `next_study_date` —
        // the only safe end boundary for the terminal coverage probe.
        var lastDecodedNextDate: Date?

        while true {
            guard !control.isCancellationRequested else { throw CompanionError.cancelled }
            let page = try await api.studyRecords(
                nextStudyDateStart: currentBoundary,
                nextStudyDateEnd: formattedEnd,
                asCount: false,
                control: control
            )
            pageIndex += 1
            var newCount = 0
            for record in page.records where seen.insert(record.vocabularyID).inserted {
                collected.append(record)
                newCount += 1
            }
            if let lastDate = page.records.last?.nextStudyDate {
                lastDecodedNextDate = lastDate
            }
            log(
                "records_page index=\(pageIndex)"
                    + " start=\(currentBoundary ?? "nil") end=\(formattedEnd ?? "nil")"
                    + " rows=\(page.records.count) new=\(newCount) total=\(collected.count)",
                runID: runID
            )
            if collected.count >= expectedTotal {
                log("records_done reason=expected_total pages=\(pageIndex)", runID: runID)
                return (collected, .complete)
            }
            guard page.records.count == CompanionConstants.studyPageSize else {
                // Terminal short page below the provider's own total: the
                // documented recipe is exhausted. Issue exactly one distinct
                // read-only coverage probe to size the gap, then fail closed.
                return try await coverageProbeOnTerminalMismatch(
                    expectedTotal: expectedTotal,
                    collected: collected,
                    finalDate: lastDecodedNextDate,
                    control: control,
                    runID: runID
                )
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

    /// One distinct read-only count probe when the documented sliding windows
    /// end at a terminal short page but unique records are still below the
    /// provider's own unfiltered `as_count` total. It sizes the gap —
    /// `count_through_final_date` vs `unique_read` — using the final decoded
    /// record's actual `next_study_date` as an exact end boundary, logs the
    /// counts, and **still fails closed**: no synthesized records, no partial
    /// export, no invented pagination. This is a diagnostic read, never an
    /// automatic retry of the failed page.
    private func coverageProbeOnTerminalMismatch(
        expectedTotal: Int,
        collected: [StudyRecord],
        finalDate: Date?,
        control: ExecutionControl,
        runID: String
    ) async throws -> (records: [StudyRecord], completeness: StudyExportCompleteness) {
        let originalMismatch = StudyExportError.recordCountMismatch(
            expected: expectedTotal, read: collected.count
        )
        guard let finalDate else {
            log(
                "records_coverage_probe skipped reason=final_date_unavailable"
                    + " expected_total=\(expectedTotal) unique_read=\(collected.count)",
                runID: runID
            )
            throw originalMismatch
        }
        let formattedFinal = StudyExportSemantics.beijingISO8601(finalDate)
        do {
            let probe = try await api.studyRecords(
                nextStudyDateStart: nil,
                nextStudyDateEnd: formattedFinal,
                asCount: true,
                control: control
            )
            let unaccounted = max(expectedTotal - collected.count, 0)
            log(
                "records_coverage_probe expected_total=\(expectedTotal)"
                    + " unique_read=\(collected.count)"
                    + " count_through_final_date=\(probe.count)"
                    + " unaccounted=\(unaccounted)"
                    + " final_date=\(formattedFinal)",
                runID: runID
            )
            throw StudyExportError.coverageGap(
                expected: expectedTotal,
                read: collected.count,
                countedThroughFinalDate: probe.count,
                finalDate: finalDate
            )
        } catch let gap as StudyExportError {
            throw gap
        } catch is CancellationError {
            throw CompanionError.cancelled
        } catch let error as CompanionError where error == .cancelled {
            throw error
        } catch {
            // A failed probe never replaces the original truthful mismatch.
            log(
                "records_coverage_probe_error category=\(StudyExportDiagnosticCategory.sanitized(error))"
                    + " final_date=\(formattedFinal)",
                runID: runID
            )
            throw originalMismatch
        }
    }
}
