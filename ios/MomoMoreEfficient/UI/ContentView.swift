import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: CompanionViewModel
    @State private var showingTokenSheet = false
    @State private var tokenDraft = ""

    init(viewModel: @autoclosure @escaping () -> CompanionViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                rehearsalBanner
                accountRow
                modePicker
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if viewModel.isShowingEditor {
                            editorSurface
                        } else if viewModel.contentMode == .phrase,
                                  let preview = viewModel.phrasePreview {
                            phrasePreviewSurface(preview)
                        } else if let preview = viewModel.preview {
                            previewSurface(preview)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(viewModel.contentMode.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("历史") {
                        HistoryListView(viewModel: viewModel)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !viewModel.executionActions.isEmpty
                    || viewModel.canExecutePhrase
                    || viewModel.isExecuting {
                    executionBar
                }
            }
        }
        .sheet(isPresented: $showingTokenSheet, onDismiss: clearTokenDraft) {
            tokenSheet
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { viewModel.pendingConfirmation != nil },
                set: { if !$0 { viewModel.cancelPendingConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            if let group = viewModel.pendingConfirmation {
                Button(group == .create ? "确认执行新建" : "确认执行更新", role: .destructive) {
                    viewModel.executeConfirmed(group)
                }
            }
            Button("取消", role: .cancel) { viewModel.cancelPendingConfirmation() }
        } message: {
            Text("将重新完整预检；只有结果与当前预览严格一致时才会顺序写入。每项最多一次 POST，不重试。")
        }
        .confirmationDialog(
            viewModel.pendingBatchConfirmation?.title ?? "确认执行？",
            isPresented: Binding(
                get: { viewModel.pendingBatchConfirmation != nil },
                set: { if !$0 { viewModel.cancelPendingConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = viewModel.pendingBatchConfirmation {
                Button(pending.actionTitle, role: .destructive) {
                    viewModel.executeConfirmedWholePlan()
                }
            }
            Button("取消", role: .cancel) { viewModel.cancelPendingConfirmation() }
        } message: {
            // One approval, stating the total, both memberships and the digest that
            // commits it to this exact Preview and to both subplans.
            Text(viewModel.pendingBatchConfirmation?.message ?? "")
        }
        .confirmationDialog(
            viewModel.pendingPhraseConfirmation?.title ?? "确认新建例句？",
            isPresented: Binding(
                get: { viewModel.pendingPhraseConfirmation != nil },
                set: { if !$0 { viewModel.cancelPendingConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = viewModel.pendingPhraseConfirmation {
                Button(pending.actionTitle, role: .destructive) {
                    viewModel.executeConfirmedPhrase()
                }
            }
            Button("取消", role: .cancel) { viewModel.cancelPendingConfirmation() }
        } message: {
            Text(viewModel.pendingPhraseConfirmation?.message ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                viewModel.enterForeground()
            case .inactive, .background:
                viewModel.enterBackground()
            @unknown default:
                viewModel.enterBackground()
            }
        }
    }

    @ViewBuilder
    private var rehearsalBanner: some View {
        if RehearsalMode.isEnabled {
            Text("演练模式 · 无真实 Token · 不访问墨墨 · 不产生真实写入")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.purple)
        }
    }

    private var accountRow: some View {
        HStack(spacing: 10) {
            Text("墨墨账号")
                .font(.subheadline.weight(.semibold))
            Text(viewModel.isConnected ? "✓ 已连接" : "未连接")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            NavigationLink("录入偏好") {
                ImportPreferencesView(viewModel: viewModel)
            }
            .font(.subheadline)
            .disabled(viewModel.isBusy)
            if viewModel.isConnected {
                Menu("更换") {
                    Button("更换 Token") { showingTokenSheet = true }
                    Button("移除 Token", role: .destructive) { viewModel.removeToken() }
                }
                .disabled(viewModel.isBusy)
            } else {
                Button("连接") { showingTokenSheet = true }
                    .disabled(viewModel.isBusy)
            }
        }
        .padding(.horizontal)
        .frame(minHeight: 44)
    }

    private var modePicker: some View {
        Picker("内容类型", selection: Binding(
            get: { viewModel.contentMode },
            set: { viewModel.selectMode($0) }
        )) {
            ForEach(ContentMode.allCases, id: \.self) { mode in
                Text(mode.pickerLabel).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!viewModel.canSwitchMode)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityLabel("录入模式")
    }

    private var editorSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let acknowledgement = viewModel.completionAcknowledgement {
                Text(acknowledgement)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            }

            TextEditor(text: $viewModel.sourceText)
                .frame(minHeight: 140, maxHeight: 190)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(viewModel.contentMode.editorAccessibilityLabel)

            if viewModel.contentMode == .phrase {
                Text("格式：单词 · 英文例句 · 中文翻译 · 来源（可选）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let parseMessage = viewModel.localParseState.message {
                Text(parseMessage)
                    .font(.footnote)
                    .foregroundStyle(viewModel.localParseState.isValid ? Color.secondary : Color.red)
            }

            feedbackView

            Button {
                Task { await viewModel.previewCurrentInput() }
            } label: {
                HStack {
                    if viewModel.isPreviewing {
                        ProgressView()
                            .controlSize(.small)
                        Text(previewLoadingTitle)
                    } else {
                        Text("预览")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !viewModel.isConnected
                    || !viewModel.localParseState.isValid
                    || viewModel.isBusy
            )
        }
    }

    private func previewSurface(_ preview: PreviewPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.previewHeader ?? "预览")
                    .font(.headline)
                Spacer()
                Button("编辑") { viewModel.editInput() }
                    .font(.subheadline)
                    .disabled(viewModel.isBusy)
            }

            HStack(spacing: 14) {
                summaryLabel("新建", preview.counts.create)
                summaryLabel("更新", preview.counts.update)
                summaryLabel("一致", preview.counts.alreadyMatching)
                summaryLabel("阻断", preview.counts.blocked)
            }
            .font(.subheadline.monospacedDigit())

            Text(viewModel.selectedTagsSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if viewModel.isPreviewStale {
                HStack(spacing: 10) {
                    Text("需重新预览后才能写入")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("重新预览") {
                        Task { await viewModel.previewCurrentInput() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(
                        !viewModel.isConnected
                            || !viewModel.localParseState.isValid
                            || viewModel.isBusy
                    )
                }
            }

            feedbackView

            LazyVStack(spacing: 0) {
                ForEach(preview.rows) { row in
                    previewRow(row)
                    if row.id != preview.rows.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func phrasePreviewSurface(_ preview: PhrasePreviewPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.previewHeader ?? "例句预览")
                    .font(.headline)
                Spacer()
                Button("编辑") { viewModel.editInput() }
                    .font(.subheadline)
                    .disabled(viewModel.isBusy)
            }

            HStack(spacing: 14) {
                summaryLabel("新建", preview.createCount)
                summaryLabel("一致", preview.alreadyMatchingCount)
                summaryLabel("阻断", preview.blockedCount)
            }
            .font(.subheadline.monospacedDigit())

            Text(viewModel.selectedTagsSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if viewModel.isPreviewStale {
                HStack(spacing: 10) {
                    Text("需重新预览后才能写入")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("重新预览") {
                        Task { await viewModel.previewCurrentInput() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(
                        !viewModel.isConnected
                            || !viewModel.localParseState.isValid
                            || viewModel.isBusy
                    )
                }
            }

            feedbackView

            LazyVStack(spacing: 0) {
                ForEach(preview.rows) { row in
                    phrasePreviewRow(row)
                    if row.id != preview.rows.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func phrasePreviewRow(_ row: PhrasePreviewRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                viewModel.toggleDetails(for: row)
            } label: {
                HStack {
                    Text(row.spelling)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(row.classification.compactLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(phraseClassificationColor(row.classification))
                    Image(systemName: viewModel.expandedRowIDs.contains(row.id)
                        ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let reason = row.blockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if row.classification == .alreadyMatching, !row.observations.isEmpty {
                Text(phraseObservationLabel(row.observations))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.expandedRowIDs.contains(row.id) {
                detailLabel("EN", row.english)
                detailLabel("ZH", row.chinese)
                detailLabel("SOURCE", row.source ?? "未填写")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func previewRow(_ row: PreviewRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                viewModel.toggleDetails(for: row)
            } label: {
                HStack {
                    Text(row.spelling)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(row.classification.compactLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(classificationColor(row.classification))
                    if row.canExpand {
                        Image(systemName: viewModel.expandedRowIDs.contains(row.id)
                            ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.canExpand)

            if let reason = row.compactBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let details = viewModel.details(for: row) {
                if let current = details.current {
                    detailLabel("CURRENT", current)
                }
                detailLabel("PROPOSED", details.proposed)
                if let currentTags = details.currentTags,
                   let proposedTags = details.proposedTags {
                    detailLabel(
                        "TAGS",
                        "\(WriteTagPreference.compactLabel(currentTags)) → "
                            + WriteTagPreference.compactLabel(proposedTags)
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var executionBar: some View {
        Group {
            if viewModel.isExecuting {
                executionProgressRow
            } else if viewModel.contentMode == .phrase {
                Button("新建 \(viewModel.phrasePreview?.createCount ?? 0) 条例句") {
                    viewModel.askToExecutePhrase()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.canExecutePhrase)
            } else {
                HStack(spacing: 12) {
                    ForEach(viewModel.executionActions) { action in
                        Button(action.title) {
                            if action.coversWholePlan {
                                viewModel.askToExecuteWholePlan()
                            } else if let group = action.group {
                                viewModel.askToExecute(group)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(action.group == .update ? .orange : .blue)
                        .frame(maxWidth: .infinity)
                        .disabled(action.count == 0 || viewModel.isBusy)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var executionProgressRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.executionProgressLabel ?? "正在执行…")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text("短暂切换应用不会取消；若系统回收后台时间，将安全停止。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.executionProgressLabel ?? "正在执行")
    }

    @ViewBuilder
    private var feedbackView: some View {
        if viewModel.hasExecutionFeedback {
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if viewModel.contentMode == .phrase {
                        Text(
                            "例句新建成功 \(viewModel.finalSummary.created) · "
                                + "失败 \(viewModel.finalSummary.failed) · "
                                + "未执行 \(viewModel.finalSummary.notAttempted)"
                        )
                    } else {
                        Text(
                            "新建成功 \(viewModel.finalSummary.created) · "
                                + "更新成功 \(viewModel.finalSummary.updated) · "
                                + "失败 \(viewModel.finalSummary.failed) · "
                                + "未执行 \(viewModel.finalSummary.notAttempted)"
                        )
                    }
                }
                .font(.footnote.monospacedDigit())
                if let stoppedMessage = viewModel.finalSummary.stoppedMessage {
                    Text(stoppedMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        if let message = viewModel.phraseObservationMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if let message = viewModel.errorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
        if let message = viewModel.historyErrorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var tokenSheet: some View {
        NavigationStack {
            Form {
                SecureField("墨墨账号 Token", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("请在确认登录目标墨墨账号后手动粘贴。应用无法证明 Token 属于哪个账号。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(viewModel.isConnected ? "更换 Token" : "连接墨墨账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingTokenSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isConnected ? "更换" : "连接") {
                        viewModel.connect(token: &tokenDraft)
                        showingTokenSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var previewLoadingTitle: String {
        // Real per-entry read progress once the first entry has been reached.
        if let progress = viewModel.previewProgressLabel { return progress }
        if case let .valid(count, _, _) = viewModel.localParseState {
            return "正在预览 \(count) 条…"
        }
        return "正在预览…"
    }

    private var confirmationTitle: String {
        viewModel.pendingConfirmation == .update ? "确认更新现有自建释义？" : "确认新建自建释义？"
    }

    private func summaryLabel(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Text("\(value)").fontWeight(.semibold)
        }
    }

    private func detailLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func classificationColor(_ classification: PreviewClassification) -> Color {
        switch classification {
        case .create, .alreadyMatching: return .secondary
        case .update: return .orange
        case .blocked: return .red
        }
    }

    private func phraseClassificationColor(_ classification: PhrasePreviewClassification) -> Color {
        switch classification {
        case .create, .alreadyMatching: return .secondary
        case .blocked: return .red
        }
    }

    private func phraseObservationLabel(_ observations: [PhraseObservation]) -> String {
        observations.map { observation in
            switch observation {
            case .tagsMatchRequested: return "标签匹配"
            case .tagsMissing: return "标签未返回"
            case .tagsDiffer: return "标签不同"
            case .highlightExactTarget: return "英文高亮准确"
            case .highlightMissing: return "英文高亮未返回"
            case .highlightEmpty: return "英文高亮为空"
            case .highlightOtherReviewedRange: return "英文高亮为其他已审阅范围"
            case .chineseRangeUnavailable: return "中文范围不可用"
            }
        }.joined(separator: " · ")
    }

    private func clearTokenDraft() {
        tokenDraft.removeAll(keepingCapacity: false)
    }
}

private struct ImportPreferencesView: View {
    @ObservedObject var viewModel: CompanionViewModel

    var body: some View {
        List {
            Section {
                LabeledContent("发布", value: "公开")
                Text("标签：可选，最多 3 个")
                    .foregroundStyle(.secondary)
            }

            Section("标签") {
                ForEach(viewModel.availableWriteTags, id: \.self) { tag in
                    Button {
                        viewModel.toggleTag(tag)
                    } label: {
                        HStack {
                            Text(tag)
                                .foregroundStyle(.primary)
                            Spacer()
                            if viewModel.isTagSelected(tag) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(!viewModel.canToggleTag(tag))
                    .accessibilityValue(viewModel.isTagSelected(tag) ? "已选择" : "未选择")
                }
            }
        }
        .navigationTitle("录入偏好")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HistoryListView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @State private var showingClearConfirmation = false

    var body: some View {
        List {
            if let message = viewModel.historyErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if viewModel.history.isEmpty {
                ContentUnavailableView("暂无历史", systemImage: "clock.arrow.circlepath")
            } else {
                ForEach(viewModel.history) { receipt in
                    NavigationLink {
                        HistoryDetailView(receipt: receipt)
                    } label: {
                        HistoryRow(receipt: receipt)
                    }
                }
            }
        }
        .navigationTitle("历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空历史", role: .destructive) {
                    showingClearConfirmation = true
                }
                .disabled(viewModel.history.isEmpty || viewModel.isBusy)
            }
        }
        .confirmationDialog(
            "清空本地历史？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空历史", role: .destructive) { viewModel.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除本机执行回执；不会影响 Token、当前草稿或墨墨数据。")
        }
    }
}

private struct HistoryRow: View {
    let receipt: ExecutionReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(receipt.timestamp.formatted(date: .omitted, time: .shortened)) · \(receipt.contentKind.displayLabel) · \(operation) \(receipt.items.count) · \(spellingSummary)")
                .font(.subheadline)
                .lineLimit(1)
            Text(outcomeSummary)
                .font(.caption)
                .foregroundStyle(receipt.isFullSuccess ? Color.secondary : Color.orange)
        }
    }

    private var operation: String { receipt.operationGroup == .create ? "新建" : "更新" }

    private var spellingSummary: String {
        guard let first = receipt.items.first?.spelling else { return "—" }
        return receipt.items.count == 1 ? first : "\(first) 等"
    }

    private var outcomeSummary: String {
        if receipt.isFullSuccess { return "成功" }
        var parts: [String] = []
        if receipt.succeeded > 0 { parts.append("\(receipt.succeeded) 成功") }
        if receipt.failed > 0 { parts.append("\(receipt.failed) 失败") }
        if receipt.notAttempted > 0 { parts.append("\(receipt.notAttempted) 未执行") }
        return parts.joined(separator: " / ")
    }
}

private struct HistoryDetailView: View {
    let receipt: ExecutionReceipt

    var body: some View {
        List {
            Section("执行") {
                LabeledContent("时间", value: receipt.timestamp.formatted())
                LabeledContent("内容", value: receipt.contentKind.displayLabel)
                LabeledContent("操作", value: receipt.operationGroup == .create ? "CREATE" : "UPDATE")
                LabeledContent("成功", value: "\(receipt.succeeded)")
                LabeledContent("失败", value: "\(receipt.failed)")
                LabeledContent("未执行", value: "\(receipt.notAttempted)")
                LabeledContent("已停止", value: receipt.stopped ? "是" : "否")
            }
            Section("条目") {
                ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, item in
                    LabeledContent(item.spelling, value: outcomeLabel(item.finalOutcome))
                }
            }
        }
        .navigationTitle("执行回执")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func outcomeLabel(_ outcome: WriteOutcome) -> String {
        switch outcome {
        case .confirmed: return "已确认"
        case .recovered: return "已恢复确认"
        case .notVerified: return "未确认"
        case .notAttempted: return "未执行"
        }
    }
}
