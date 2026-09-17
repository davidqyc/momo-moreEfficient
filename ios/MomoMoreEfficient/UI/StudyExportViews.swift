import SwiftUI

/// 单词导出 (#155) — one lightweight read-only destination.
///
/// Preset list, one memory-only result, native copy/share. Nothing here can
/// write: the destination has no path to a mutating route, and the preset run
/// reuses exactly the same read seam and provider-operation lane as batch
/// Query. Leaving the page stops any running read — no interrupt dialog, no
/// background continuation.
struct StudyExportView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var store: StudyExportStore
    @ObservedObject var router: AppRouter
    /// The one bridge to the existing app-scoped batch Query (#161): installs
    /// the exact words into `QuerySessionStore` and opens Query. No clipboard,
    /// no auto-started reads.
    let onOpenInQuery: ([String]) -> Void

    @State private var isReviewWindowExpanded = false
    @State private var toastText: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch store.phase {
                case .idle:
                    presetList
                case let .loading(preset):
                    runningSurface(preset)
                case let .completed(preset, outcome):
                    resultSurface(preset, outcome)
                case let .failed(preset, failure):
                    failedSurface(preset, failure)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .themedScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if StudyExportDiagnosticsPolicy.isOwnerVisible {
                    diagnosticsStrip
                }
                actionBar
            }
        }
        .overlay(alignment: .bottom) {
            if let toastText {
                Toast(text: toastText)
                    .padding(.bottom, 96)
                    .transition(.opacity)
            }
        }
        // Leaving the page stops subsequent study reads and any running
        // enumerability probe; the provider operation lane is released by
        // each run's own epilogue.
        .onDisappear {
            store.logScreenDisappear()
            store.cancelProbe()
            store.stop()
        }
        .onAppear {
            store.logFeatureEntered(connected: viewModel.isConnected)
        }
    }

    // MARK: - On-device diagnostics (Owner standing rule, #155 unstable)

    /// Compact, always-visible diagnostics row: the Owner copies plain text
    /// and never needs Xcode/Console. Copy/clear never touches business state.
    private var diagnosticsStrip: some View {
        HStack(spacing: Theme.gapS) {
            Text("诊断 · 最近一次运行")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.gapS)
            NavPill(title: "复制诊断") { copyDiagnostics() }
            NavPill(title: "清除诊断") { store.clearDiagnostics() }
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.vertical, Theme.gapS)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("诊断")
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = store.diagnosticReport()
        withAnimation { toastText = "已复制诊断" }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toastText = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            PageTitle(text: "单词导出")
            ConnectionStatusLine(isConnected: viewModel.isConnected) {
                router.go(.settings)
            }
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.bottom, Theme.gapM)
    }

    private var canStart: Bool {
        viewModel.isConnected && !viewModel.isProviderLaneBusy
    }

    // MARK: - Preset list

    private var presetList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                if !viewModel.isConnected {
                    CaptionLine(text: "连接墨墨账号后可导出")
                }
                GroupedCard {
                    ForEach(Array(StudyExportPreset.all.enumerated()), id: \.element) { index, preset in
                        if index > 0 { RowDivider() }
                        if case .reviewWithin = preset {
                            reviewWindowRow
                        } else {
                            presetRow(preset)
                        }
                    }
                }
                CaptionLine(
                    text: "学习数据由墨墨公测 API 提供；需开启自动同步，当日数据可能需要先打开墨墨初始化。"
                )
                .padding(.top, Theme.gapS)
                Spacer(minLength: Theme.gapL)
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.top, Theme.gapM)
        }
    }

    private func presetRow(_ preset: StudyExportPreset) -> some View {
        Button {
            run(preset)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(Theme.row)
                        .foregroundStyle(Theme.ink)
                    Text(preset.subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.gapS)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.vertical, 14)
            .frame(minHeight: Theme.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .accessibilityLabel(preset.title)
        .accessibilityValue(preset.subtitle)
    }

    /// The fixed 1 / 3 / 7 / 30-day choices. The row itself only expands the
    /// choice; a day chip is what actually runs.
    private var reviewWindowRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { isReviewWindowExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("N 天内复习")
                            .font(Theme.row)
                            .foregroundStyle(Theme.ink)
                        Text("选择 1 / 3 / 7 / 30 天，导出期间内要复习的词")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.gapS)
                    Image(systemName: isReviewWindowExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, Theme.rowPaddingH)
                .padding(.vertical, 14)
                .frame(minHeight: Theme.minimumTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("N 天内复习")
            .accessibilityValue(isReviewWindowExpanded ? "已展开" : "未展开")
            if isReviewWindowExpanded {
                RowDivider()
                HStack(spacing: Theme.gapS) {
                    ForEach(StudyExportPreset.reviewDayChoices, id: \.self) { days in
                        Button {
                            run(.reviewWithin(days: days))
                        } label: {
                            Text("\(days) 天")
                                .font(Theme.chip)
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(
                                    Theme.surfaceMuted,
                                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canStart)
                        .accessibilityLabel("\(days) 天内复习")
                    }
                }
                .padding(.horizontal, Theme.rowPaddingH)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Running

    private func runningSurface(_ preset: StudyExportPreset) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack(spacing: Theme.gapS) {
                ProgressView().controlSize(.small).tint(Theme.ink)
                Text("正在读取\(preset.title)…")
                    .font(Theme.row)
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, Theme.pageMargin)
            CaptionLine(text: "读取完成前不产生可复制的名单；离开本页会停止读取。")
                .padding(.horizontal, Theme.pageMargin)
        }
        .padding(.top, Theme.gapL)
    }

    // MARK: - Result

    private func resultSurface(_ preset: StudyExportPreset, _ outcome: StudyExportOutcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            if let banner = completenessBanner(outcome.completeness) {
                banner
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(preset.title) · \(outcome.words.count) 个")
                    .font(Theme.row.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.gapS)
            }
            if outcome.words.isEmpty {
                CaptionLine(text: "确认没有符合条件的词。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(outcome.words.enumerated()), id: \.offset) { index, word in
                            if index > 0 { RowDivider() }
                            Text(word)
                                .font(Theme.row)
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.rowPaddingH)
                                .padding(.vertical, 10)
                                .textSelection(.enabled)
                        }
                    }
                    .themedCard()
                }
            }
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.top, Theme.gapM)
    }

    private func completenessBanner(_ completeness: StudyExportCompleteness) -> Banner? {
        switch completeness {
        case .complete:
            return nil
        case .cappedAtSingleCallLimit:
            return Banner(
                title: "结果可能不完整",
                message: "读取达到了墨墨单次接口上限（1000 个），可能还有词没有取到。名单可以照常复制。",
                tone: .stop
            )
        case let .mismatchedWithProgress(finished, read):
            return Banner(
                title: "结果可能不完整",
                message: "今日进度显示已完成 \(finished) 个，实际读取到 \(read) 个。"
                    + "墨墨当日数据可能还未初始化；名单可以照常复制。",
                tone: .stop
            )
        case let .mismatchedWithRemainingProgress(remaining, read):
            return Banner(
                title: "结果可能不完整",
                message: "今日进度显示还剩 \(remaining) 个，实际读取到 \(read) 个。"
                    + "墨墨当日数据可能还未同步完整；名单可以照常使用，但结果可能不完整。",
                tone: .stop
            )
        }
    }

    // MARK: - Failure

    private func failedSurface(_ preset: StudyExportPreset, _ failure: StudyExportStore.Failure) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                Banner(
                    title: failure.title,
                    message: failure.message,
                    tone: .stop
                )
                // The enumerability probe unlocks only on the coverageGap
                // failure, and runs only as an explicit user action.
                if store.showsCoverageProbe {
                    coverageProbeSection
                }
                CaptionLine(text: "不会自动重试；点按下方按钮重试，或返回列表。")
                Spacer(minLength: Theme.gapL)
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.top, Theme.gapM)
        }
    }

    /// The #155 diagnostic-only enumerability probe surface: explicit action,
    /// read-only copy, counts-only result. No word list is ever produced here.
    @ViewBuilder
    private var coverageProbeSection: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            GroupedCard(title: "完整性探针") {
                VStack(alignment: .leading, spacing: Theme.gapS) {
                    switch store.probePhase {
                    case .idle:
                        PrimaryPillButton(title: "运行完整性探针", isEnabled: viewModel.isConnected && !viewModel.isProviderLaneBusy) {
                            runCoverageProbe()
                        }
                        CaptionLine(text: "只读取。将按日期区间核对墨墨 count 与可枚举 records，不会导出或修改学习数据。")
                    case .running:
                        HStack(spacing: Theme.gapS) {
                            ProgressView().controlSize(.small).tint(Theme.ink)
                            Text("完整性探针运行中…")
                                .font(Theme.row)
                                .foregroundStyle(Theme.ink)
                        }
                        CaptionLine(text: "最多 32 次只读请求；离开本页会停止探针。")
                    case let .completed(verdict):
                        AckLine(text: "完整性探针：已完成 · \(verdict.chineseLabel)")
                    }
                }
                .padding(Theme.rowPaddingH)
            }
        }
    }

    private func runCoverageProbe() {
        guard viewModel.isConnected, !viewModel.isProviderLaneBusy,
              let lease = viewModel.beginQueryRead()
        else { return }
        store.startCoverageProbe(lease: lease)
    }

    // MARK: - Bottom actions

    @ViewBuilder
    private var actionBar: some View {
        switch store.phase {
        case .idle:
            EmptyView()
        case .loading:
            actionBarContainer {
                PrimaryPillButton(title: "停止") {
                    store.stop()
                }
            }
        case let .failed(preset, _):
            actionBarContainer {
                HStack(spacing: 12) {
                    SecondaryPillButton(title: "返回列表") {
                        store.returnToPresetList()
                    }
                    PrimaryPillButton(title: "重试") {
                        run(preset)
                    }
                }
            }
        case let .completed(preset, outcome):
            actionBarContainer {
                VStack(spacing: Theme.gapS) {
                    HStack(spacing: 12) {
                        SecondaryPillButton(title: "返回列表") {
                            store.returnToPresetList()
                        }
                        if outcome.words.isEmpty {
                            PrimaryPillButton(title: "复制 0 个单词", isEnabled: false) {}
                        } else {
                            PrimaryPillButton(title: "复制 \(outcome.words.count) 个单词") {
                                copyWords()
                            }
                        }
                    }
                    if !outcome.words.isEmpty {
                        PrimaryPillButton(title: "批量查阅 \(outcome.words.count) 个") {
                            openInQuery(outcome.words)
                        }
                        if let payload = store.copyPayload {
                            ShareLink(item: payload) {
                                Text("分享")
                                    .font(Theme.primaryButton)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
                                    .background(
                                        Theme.surface,
                                        in: RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                                            .strokeBorder(Theme.separator, lineWidth: Theme.hairline)
                                    )
                            }
                            .accessibilityLabel("分享 \(outcome.words.count) 个单词")
                        }
                    }
                }
            }
        }
    }

    private func actionBarContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, Theme.pageMargin)
                .padding(.vertical, Theme.gapM)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
        }
    }

    // MARK: - Actions

    /// The direct Study Export → Query handoff: logs only the count, hands
    /// over the exact words, and lets the ContentView bridge install them
    /// into the existing Query store and navigate. No clipboard, and Query's
    /// provider reads never auto-start here.
    private func openInQuery(_ words: [String]) {
        store.logQueryHandoff(count: words.count)
        onOpenInQuery(words)
    }

    private func run(_ preset: StudyExportPreset) {
        store.logPresetTap(
            preset: preset,
            connected: viewModel.isConnected,
            laneBusy: viewModel.isProviderLaneBusy
        )
        guard canStart, let lease = viewModel.beginQueryRead() else {
            store.logLeaseOutcome(acquired: false, preset: preset)
            return
        }
        store.logLeaseOutcome(acquired: true, preset: preset)
        store.start(preset, lease: lease)
    }

    private func copyWords() {
        guard let payload = store.copyPayload else { return }
        UIPasteboard.general.string = payload
        let count = store.resultWordCount ?? 0
        withAnimation { toastText = "已复制 \(count) 个单词" }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toastText = nil }
        }
    }
}
