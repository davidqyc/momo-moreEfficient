import SwiftUI

/// The one write destination.
///
/// Editor, Preview, confirmation and execution feedback are **state inside this
/// destination**, exactly as they were before the retrofit: `释义 | 例句` switches
/// view-model state, never the navigation path, so `.write` can never appear
/// twice on the stack. Every write-safety rule is unchanged — this view moved,
/// the machinery did not.
struct WriteSurfaceView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var router: AppRouter

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if viewModel.isShowingEditor {
                    editorSurface
                } else if viewModel.contentMode == .phrase,
                          let preview = viewModel.phrasePreview {
                    phrasePreviewSurface(preview)
                } else if let preview = viewModel.preview {
                    previewSurface(preview)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .themedScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(text: viewModel.contentMode.navigationTitle)
                Spacer(minLength: Theme.gapS)
                NavPill(
                    title: viewModel.contentMode == .interpretation ? "释义历史" : "例句历史"
                ) {
                    router.go(.history(viewModel.contentMode))
                }
            }
            ConnectionStatusLine(isConnected: viewModel.isConnected) {
                router.go(.settings)
            }
            SegmentControl(
                values: ContentMode.allCases,
                label: \.pickerLabel,
                selection: Binding(
                    get: { viewModel.contentMode },
                    set: { viewModel.selectMode($0) }
                ),
                isEnabled: viewModel.canSwitchMode
            )
            .accessibilityLabel("录入模式")
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.bottom, Theme.gapM)
    }

    // MARK: - Editor

    private var editorSurface: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            if let acknowledgement = viewModel.completionAcknowledgement {
                AckLine(text: acknowledgement)
            }
            if viewModel.cameFromCapture {
                CaptionLine(text: "来自抓词 · 尚未预览")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.sourceText)
                    .font(Theme.row)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(viewModel.contentMode.editorAccessibilityLabel)
                if viewModel.sourceText.isEmpty {
                    Text(viewModel.contentMode.editorHint)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 14)
                        .padding(.leading, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedCard()

            if let parseMessage = viewModel.localParseState.message {
                Text(parseMessage)
                    .font(Theme.label)
                    .foregroundStyle(
                        viewModel.localParseState.isValid ? Theme.textSecondary : Theme.alert
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            feedbackView
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.bottom, Theme.gapM)
    }

    // MARK: - Preview

    private func previewSurface(_ preview: PreviewPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                previewHeaderRow(
                    count: preview.rows.count,
                    unit: "条释义",
                    first: preview.rows.first?.spelling,
                    last: preview.rows.last?.spelling
                )
                HStack(spacing: 14) {
                    summaryLabel("新建", preview.counts.create)
                    summaryLabel("更新", preview.counts.update)
                    summaryLabel("一致", preview.counts.alreadyMatching, emphasized: false)
                    summaryLabel("阻断", preview.counts.blocked, isAlert: true)
                }
                CaptionLine(text: viewModel.selectedTagsSummary)
                if preview.counts.create == 0,
                   preview.counts.update == 0,
                   preview.counts.blocked == 0 {
                    CaptionLine(text: "全部一致 · 没有需要写入的项")
                }
                stalePreviewRow
                feedbackView

                VStack(spacing: 0) {
                    ForEach(Array(preview.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        previewRow(row)
                    }
                }
                .themedCard()
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.bottom, Theme.gapM)
        }
    }

    private func phrasePreviewSurface(_ preview: PhrasePreviewPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                previewHeaderRow(
                    count: preview.rows.count,
                    unit: "条例句",
                    first: preview.rows.first?.spelling,
                    last: preview.rows.last?.spelling
                )
                HStack(spacing: 14) {
                    summaryLabel("新建", preview.createCount)
                    summaryLabel("一致", preview.alreadyMatchingCount, emphasized: false)
                    summaryLabel("阻断", preview.blockedCount, isAlert: true)
                }
                CaptionLine(text: viewModel.selectedTagsSummary)
                if preview.blockedCount > 0 {
                    CaptionLine(text: "含 \(preview.blockedCount) 条阻断 · 修正后重新预览才可新建")
                }
                stalePreviewRow
                feedbackView

                VStack(spacing: 0) {
                    ForEach(Array(preview.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        phrasePreviewRow(row)
                    }
                }
                .themedCard()
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.bottom, Theme.gapM)
        }
    }

    private func previewHeaderRow(
        count: Int,
        unit: String,
        first: String?,
        last: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gapS) {
            Text("\(count) \(unit)")
                .font(Theme.row.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            if let first, let last {
                Text("\(first) → \(last)")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("编辑") { viewModel.editInput() }
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .disabled(viewModel.isBusy)
                .minimumHitArea()
        }
    }

    @ViewBuilder
    private var stalePreviewRow: some View {
        if viewModel.isPreviewStale {
            HStack(spacing: Theme.gapS) {
                if viewModel.isPreviewing {
                    ProgressView()
                    Text(previewLoadingTitle(repreview: true))
                        .font(Theme.label)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                } else {
                    Text(viewModel.staleReason ?? "需重新预览后才能写入")
                        .font(Theme.label)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.gapS)
                    Button("重新预览") {
                        Task { await viewModel.previewCurrentInput() }
                    }
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .disabled(
                        !viewModel.isConnected
                            || !viewModel.localParseState.isValid
                            || viewModel.isBusy
                    )
                    .minimumHitArea()
                }
            }
            .padding(Theme.rowPaddingH)
            .background(
                Theme.staleTint,
                in: RoundedRectangle(cornerRadius: Theme.radiusBanner, style: .continuous)
            )
            .accessibilityElement(children: .contain)
        }
    }

    private func previewRow(_ row: PreviewRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            Button {
                viewModel.toggleDetails(for: row)
            } label: {
                HStack {
                    Text(row.spelling)
                        .font(Theme.row)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(row.classification.compactLabel)
                        .font(Theme.body)
                        .fontWeight(row.classification == .blocked ? .semibold : .regular)
                        .foregroundStyle(classificationColor(row.classification))
                    if row.canExpand {
                        Image(systemName: viewModel.expandedRowIDs.contains(row.id)
                            ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.canExpand)

            if let reason = row.compactBlockedReason {
                Text(reason)
                    .font(Theme.label.weight(.semibold))
                    .foregroundStyle(Theme.alert)
            }

            if let details = viewModel.details(for: row) {
                VStack(alignment: .leading, spacing: 10) {
                    if let current = details.current {
                        detailLabel("现有", current)
                    }
                    detailLabel("拟写入", details.proposed)
                    if let currentTags = details.currentTags,
                       let proposedTags = details.proposedTags {
                        detailLabel(
                            "标签",
                            "\(WriteTagPreference.compactLabel(currentTags)) → "
                                + WriteTagPreference.compactLabel(proposedTags)
                        )
                    }
                    if row.classification == .update {
                        detailLabel("状态", viewModel.publicationPreference.label)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, 12)
    }

    private func phrasePreviewRow(_ row: PhrasePreviewRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            Button {
                viewModel.toggleDetails(for: row)
            } label: {
                HStack {
                    Text(row.spelling)
                        .font(Theme.row)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(row.classification.compactLabel)
                        .font(Theme.body)
                        .fontWeight(row.classification == .blocked ? .semibold : .regular)
                        .foregroundStyle(phraseClassificationColor(row.classification))
                    Image(systemName: viewModel.expandedRowIDs.contains(row.id)
                        ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let reason = row.blockedReason {
                Text(reason)
                    .font(Theme.label.weight(.semibold))
                    .foregroundStyle(Theme.alert)
            }

            if viewModel.expandedRowIDs.contains(row.id) {
                VStack(alignment: .leading, spacing: 10) {
                    detailLabel("英文", row.english)
                    detailLabel("中文", row.chinese)
                    detailLabel("来源", row.source ?? "未填写", secondaryValue: true)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, 12)
    }

    // MARK: - Bottom action bar

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: Theme.gapS) {
            if viewModel.isShowingEditor {
                if !viewModel.isConnected {
                    CaptionLine(text: "连接墨墨账号后可预览")
                }
                PrimaryPillButton(
                    title: previewButtonTitle,
                    isLoading: viewModel.isPreviewing,
                    isEnabled: viewModel.isConnected
                        && viewModel.localParseState.isValid
                        && !viewModel.isBusy
                ) {
                    Task { await viewModel.previewCurrentInput() }
                }
            } else if viewModel.isExecuting {
                executionProgressRow
            } else if viewModel.contentMode == .phrase {
                PrimaryPillButton(
                    title: "新建 \(viewModel.phrasePreview?.createCount ?? 0) 条例句",
                    isEnabled: viewModel.canExecutePhrase
                ) {
                    viewModel.askToExecutePhrase()
                }
            } else if !viewModel.executionActions.isEmpty {
                HStack(spacing: 12) {
                    ForEach(viewModel.executionActions) { action in
                        PrimaryPillButton(
                            title: action.title,
                            isEnabled: action.count > 0 && !viewModel.isBusy
                        ) {
                            if action.coversWholePlan {
                                viewModel.askToExecuteWholePlan()
                            } else if let group = action.group {
                                viewModel.askToExecute(group)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.vertical, Theme.gapM)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
        }
    }

    private var executionProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.gapS) {
                ProgressView()
                Text(viewModel.executionProgressLabel ?? "正在执行…")
                    .font(Theme.primaryButton)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .background(
                Theme.surfaceMuted,
                in: RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
            )
            CaptionLine(text: "短暂切换应用不会取消；若系统回收后台时间，将安全停止。")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.executionProgressLabel ?? "正在执行")
    }

    private var previewButtonTitle: String {
        if viewModel.isPreviewing { return previewLoadingTitle() }
        if case let .valid(count, _, _) = viewModel.localParseState {
            return "预览 \(count) 条"
        }
        return "预览"
    }

    // MARK: - Feedback

    @ViewBuilder
    private var feedbackView: some View {
        if viewModel.hasExecutionFeedback {
            VStack(alignment: .leading, spacing: 3) {
                Text(executionFeedbackSummary)
                    .font(Theme.label)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                if let stoppedMessage = viewModel.finalSummary.stoppedMessage {
                    Text(stoppedMessage)
                        .font(Theme.label)
                        .foregroundStyle(Theme.alert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let message = viewModel.phraseObservationMessage {
            CaptionLine(text: message)
        }
        if let message = viewModel.errorMessage {
            ErrorLine(text: message)
        }
        if let message = viewModel.historyErrorMessage {
            ErrorLine(text: message)
        }
    }

    private var executionFeedbackSummary: String {
        var parts: [String]
        if viewModel.contentMode == .phrase {
            parts = ["例句新建成功 \(viewModel.finalSummary.created)"]
        } else {
            parts = [
                "新建成功 \(viewModel.finalSummary.created)",
                "更新成功 \(viewModel.finalSummary.updated)",
            ]
        }
        if viewModel.finalSummary.unconfirmed > 0 {
            parts.append("未确认 \(viewModel.finalSummary.unconfirmed)")
        }
        if viewModel.finalSummary.failed > 0 {
            parts.append("失败 \(viewModel.finalSummary.failed)")
        }
        if viewModel.finalSummary.notAttempted > 0 {
            parts.append("未执行 \(viewModel.finalSummary.notAttempted)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private func previewLoadingTitle(repreview: Bool = false) -> String {
        if repreview {
            if let progress = viewModel.previewProgress {
                return "正在重新预览 \(progress.entry)/\(progress.total)…"
            }
            return "正在重新预览…"
        }
        if let progress = viewModel.previewProgressLabel { return progress }
        if case let .valid(count, _, _) = viewModel.localParseState {
            return "正在预览 \(count) 条…"
        }
        return "正在预览…"
    }

    private func summaryLabel(
        _ title: String,
        _ value: Int,
        emphasized: Bool = true,
        isAlert: Bool = false
    ) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Text("\(value)")
        }
        .font(Theme.body)
        .monospacedDigit()
        .fontWeight(emphasized && value > 0 ? .semibold : .regular)
        .foregroundStyle(
            value > 0 ? (isAlert ? Theme.alert : Theme.ink) : Theme.textSecondary
        )
        .accessibilityElement(children: .combine)
    }

    private func detailLabel(
        _ title: String,
        _ value: String,
        secondaryValue: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Theme.body)
                .lineSpacing(2)
                .foregroundStyle(secondaryValue ? Theme.textSecondary : Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func classificationColor(_ classification: PreviewClassification) -> Color {
        switch classification {
        case .create, .update: return Theme.ink
        case .alreadyMatching: return Theme.textSecondary
        case .blocked: return Theme.alert
        }
    }

    private func phraseClassificationColor(_ classification: PhrasePreviewClassification) -> Color {
        switch classification {
        case .create: return Theme.ink
        case .alreadyMatching: return Theme.textSecondary
        case .blocked: return Theme.alert
        }
    }
}
