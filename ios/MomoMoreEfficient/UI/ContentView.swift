import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = CompanionViewModel()
    @State private var showingTokenSheet = false
    @State private var tokenDraft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                accountRow
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if viewModel.isShowingEditor {
                            editorSurface
                        } else if let preview = viewModel.preview {
                            previewSurface(preview)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("释义录入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("历史") {
                        HistoryListView(viewModel: viewModel)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !viewModel.executionActions.isEmpty {
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

    private var accountRow: some View {
        HStack(spacing: 10) {
            Text("主账号")
                .font(.subheadline.weight(.semibold))
            Text(viewModel.isConnected ? "✓ 已连接" : "未连接")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
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
                .accessibilityLabel("批次释义输入")

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
            }

            HStack(spacing: 14) {
                summaryLabel("新建", preview.counts.create)
                summaryLabel("更新", preview.counts.update)
                summaryLabel("一致", preview.counts.alreadyMatching)
                summaryLabel("阻断", preview.counts.blocked)
            }
            .font(.subheadline.monospacedDigit())

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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var executionBar: some View {
        HStack(spacing: 12) {
            ForEach(viewModel.executionActions) { action in
                Button(action.title) {
                    viewModel.askToExecute(action.group)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.group == .create ? .blue : .orange)
                .frame(maxWidth: .infinity)
                .disabled(action.count == 0 || viewModel.isBusy)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var feedbackView: some View {
        if viewModel.hasExecutionFeedback {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    "新建成功 \(viewModel.finalSummary.created) · "
                        + "更新成功 \(viewModel.finalSummary.updated) · "
                        + "失败 \(viewModel.finalSummary.failed) · "
                        + "未执行 \(viewModel.finalSummary.notAttempted)"
                )
                .font(.footnote.monospacedDigit())
                if let stoppedMessage = viewModel.finalSummary.stoppedMessage {
                    Text(stoppedMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
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
                SecureField("主账号 Token", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("请在确认登录目标主账号后手动粘贴。应用无法证明 Token 属于哪个账号。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(viewModel.isConnected ? "更换 Token" : "连接主账号")
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

    private func clearTokenDraft() {
        tokenDraft.removeAll(keepingCapacity: false)
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
                .disabled(viewModel.history.isEmpty)
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
            Text("\(receipt.timestamp.formatted(date: .omitted, time: .shortened)) · \(operation) \(receipt.items.count) · \(spellingSummary)")
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
