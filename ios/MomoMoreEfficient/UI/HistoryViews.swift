import SwiftUI

/// Contextual History: `释义历史` or `例句历史`.
///
/// **Presentation only.** There is one receipt store; the mode the Owner came
/// from filters what is listed. `清空历史` remains global to that one store and
/// says so, so a filtered screen cannot imply a narrower destructive scope.
struct HistoryListView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var router: AppRouter
    /// Frozen at entry, so the list cannot drift from the mode it was opened for.
    let mode: ContentMode

    @State private var showingClearConfirmation = false

    private var receipts: [ExecutionReceipt] {
        viewModel.history.filter { $0.contentKind == mode.receiptContentKind }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(text: mode == .interpretation ? "释义历史" : "例句历史")
                    Spacer(minLength: Theme.gapS)
                    NavPill(
                        title: "清空历史",
                        isEnabled: !viewModel.history.isEmpty && !viewModel.isBusy
                    ) {
                        showingClearConfirmation = true
                    }
                }
                .padding(.horizontal, Theme.textInset)

                if let message = viewModel.historyErrorMessage {
                    ErrorLine(text: "历史记录读取失败 · 本机回执文件暂时无法读取")
                        .padding(.horizontal, Theme.textInset)
                        .accessibilityLabel(message)
                }
                if let acknowledgement = viewModel.historyAcknowledgement {
                    AckLine(text: acknowledgement)
                        .padding(.horizontal, Theme.textInset)
                }

                if receipts.isEmpty {
                    CaptionLine(text: "暂无历史")
                        .padding(.horizontal, Theme.textInset)
                        .padding(.top, Theme.gapL)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(receipts.enumerated()), id: \.element.id) { index, receipt in
                            if index > 0 { RowDivider() }
                            Button {
                                router.go(.receipt(receipt.id))
                            } label: {
                                HistoryRow(receipt: receipt)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .themedCard()
                    .padding(.horizontal, Theme.pageMargin)
                }

                Spacer(minLength: Theme.gapL)
            }
            .padding(.top, Theme.gapS)
        }
        .themedScreen()
        .confirmationDialog(
            "清空本地历史？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空历史", role: .destructive) { viewModel.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            // Truthful about the real scope: one store, both content kinds.
            Text(
                "只删除本机执行回执；不会影响 Token、当前草稿或墨墨数据。"
                    + "释义与例句的回执都会被清空。"
            )
        }
    }
}

private struct HistoryRow: View {
    let receipt: ExecutionReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                "\(receipt.contentKind.displayLabel) · \(operation) "
                    + "\(receipt.items.count) · \(spellingSummary)"
            )
            .font(Theme.row)
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            (
                Text("\(receipt.timestamp.formatted(date: .omitted, time: .shortened)) · ")
                    .foregroundStyle(Theme.textSecondary)
                    + Text(outcomeSummary)
                    .foregroundStyle(outcomeColor)
            )
            .font(Theme.label)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
        if receipt.unconfirmed > 0 { parts.append("\(receipt.unconfirmed) 未确认") }
        if receipt.failed > 0 { parts.append("\(receipt.failed) 失败") }
        if receipt.notAttempted > 0 { parts.append("\(receipt.notAttempted) 未执行") }
        return parts.joined(separator: " / ")
    }

    /// Success is ink with no green; only a real failure uses the alert role.
    private var outcomeColor: Color {
        if receipt.isFullSuccess { return Theme.ink }
        return receipt.failed > 0 ? Theme.alert : Theme.textSecondary
    }
}

struct HistoryDetailView: View {
    let receipt: ExecutionReceipt

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapL) {
                PageTitle(text: "执行回执")
                    .padding(.horizontal, Theme.textInset)

                GroupedCard(title: "执行") {
                    detailRow("时间", receipt.timestamp.formatted())
                    RowDivider()
                    detailRow("内容", receipt.contentKind.displayLabel)
                    RowDivider()
                    detailRow("操作", receipt.operationGroup == .create ? "新建" : "更新")
                    if let publication = receipt.publicationLabel {
                        RowDivider()
                        detailRow("发布", publication)
                    }
                    RowDivider()
                    detailRow("成功", "\(receipt.succeeded)")
                    RowDivider()
                    detailRow("未确认", "\(receipt.unconfirmed)")
                    RowDivider()
                    detailRow("失败", "\(receipt.failed)")
                    RowDivider()
                    detailRow("未执行", "\(receipt.notAttempted)")
                    RowDivider()
                    detailRow("已停止", receipt.stopped ? "是" : "否")
                }

                GroupedCard(title: "条目") {
                    ForEach(Array(receipt.items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { RowDivider() }
                        detailRow(item.spelling, item.outcomeDisplayLabel)
                    }
                }

                if receipt.hasDiagnosticDetails {
                    GroupedCard(title: "诊断") {
                        VStack(alignment: .leading, spacing: Theme.gapM) {
                            ForEach(Array(receipt.items.enumerated()), id: \.offset) { index, item in
                                if let diagnostic = item.diagnostic {
                                    diagnosticBlock(item, diagnostic, fallbackOrdinal: index + 1)
                                }
                            }
                            ShareLink(
                                "复制或分享诊断信息",
                                item: receipt.sanitizedDiagnosticText
                            )
                            .font(Theme.body.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.rowPaddingH)
                    }
                }

                Spacer(minLength: Theme.gapL)
            }
            .padding(.top, Theme.gapS)
        }
        .themedScreen()
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GroupedRow(label: label) { RowValue(text: value) }
    }

    private func diagnosticBlock(
        _ item: ExecutionReceiptItem,
        _ diagnostic: WriteAttemptDiagnostic,
        fallbackOrdinal: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("第 \(item.ordinal > 0 ? item.ordinal : fallbackOrdinal) 条 · \(item.spelling)")
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("POST：\(diagnostic.postDispatch.displayLabel)")
            Text(
                "回读：" + (diagnostic.readbackAttempts.isEmpty
                    ? "0 次"
                    : diagnostic.readbackAttempts
                        .map { $0.category.displayLabel }
                        .joined(separator: " → "))
            )
            if let facts = diagnostic.readbackAttempts.last?.phraseFacts {
                Text("记录：有效 \(facts.activeRecordCount) · 相同英文 \(facts.sameEnglishCount)")
                if !facts.mismatchKeys.isEmpty {
                    Text("不一致：" + facts.mismatchKeys.map(\.rawValue).joined(separator: "、"))
                }
            }
            if let terminal = diagnostic.terminalErrorCategory {
                Text("终止错误：\(terminal.rawValue)")
            }
        }
        .font(Theme.label)
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ContentMode {
    /// The receipt kind a work mode's contextual History presents.
    var receiptContentKind: ReceiptContentKind {
        self == .interpretation ? .interpretation : .phrase
    }
}
