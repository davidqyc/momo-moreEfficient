import SwiftUI

/// 批量查阅 — one destination, several phases.
///
/// Input, resolving, reading, stopped and completed are **state inside this
/// destination**; the only pushed child is a row's detail. Nothing here can
/// write: the view has no path to a mutating route.
struct QueryView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var store: QuerySessionStore
    @ObservedObject var router: AppRouter

    @State private var toastText: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if store.phase.hasResult {
                    resultsSurface
                } else {
                    inputSurface
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .themedScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .overlay(alignment: .bottom) {
            if let toastText {
                Toast(text: toastText)
                    .padding(.bottom, 96)
                    .transition(.opacity)
            }
        }
        .confirmationDialog(
            "查阅仍在进行",
            isPresented: Binding(
                get: { store.pendingInterrupt != nil },
                set: { if !$0 { store.dismissInterrupt() } }
            ),
            titleVisibility: .visible
        ) {
            if let interrupt = store.pendingInterrupt {
                Button(interrupt == .modify ? "停止并修改" : "停止并返回", role: .destructive) {
                    store.resolveInterrupt(interrupt)
                    if interrupt == .back { router.popToHome() }
                }
            }
            Button("继续查阅", role: .cancel) { store.dismissInterrupt() }
        } message: {
            Text(interruptMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            PageTitle(text: "批量查阅")
            ConnectionStatusLine(isConnected: viewModel.isConnected) {
                router.go(.settings)
            }
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.bottom, Theme.gapM)
    }

    // MARK: - Input phase

    private var inputSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                if store.accountChangedBanner {
                    Banner(
                        title: "账号已更换 · 请重新查阅",
                        message: "上次的查阅结果、筛选与位置已清除；输入已保留。"
                            + "不同账号的结果不会混用。"
                    )
                }
                if store.returnableResult {
                    Banner(
                        title: "原结果仍保留",
                        message: "未修改文字前返回，直接回到原结果（含筛选与位置），不会重新读取。",
                        actionTitle: "返回结果",
                        action: { store.returnToResult() }
                    )
                }

                CaptionLine(text: "只读取，不写入")

                ZStack(alignment: .topLeading) {
                    TextEditor(
                        text: Binding(
                            get: { store.inputText },
                            set: { store.updateInput($0) }
                        )
                    )
                    .font(Theme.row)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 220)
                    .accessibilityLabel("批量查阅输入")
                    if store.inputText.isEmpty {
                        Text("每行一个词；也可用逗号或中文逗号分隔。不会拆开空格、- 或 /。")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 14)
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .themedCard()

                if store.isMalformedInput {
                    ErrorLine(text: "无法识别当前输入 · 请用换行或逗号分隔")
                } else if let parse = store.parse, !parse.isEmpty,
                          let first = parse.inputs.first?.spelling,
                          let last = parse.inputs.last?.spelling {
                    Text("已识别 \(parse.visibleCount) 项 · \(first) → \(last)")
                        .font(Theme.label)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let advisory = store.budget.advisory {
                    CaptionLine(text: advisory)
                }

                Spacer(minLength: Theme.gapL)
            }
            .padding(.horizontal, Theme.pageMargin)
        }
    }

    // MARK: - Results phase

    private var resultsSurface: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            if store.accountChangedBanner {
                Banner(
                    title: "账号已更换 · 请重新查阅",
                    message: "上次的查阅结果、筛选与位置已清除；输入已保留。"
                )
                .padding(.horizontal, Theme.pageMargin)
            }
            if case let .stopped(reason) = store.phase, case .globalFailure = reason {
                Banner(
                    title: reason.bannerTitle,
                    message: reason.bannerBody(
                        read: store.completedRowCount,
                        remaining: store.unfinishedRowCount
                    ),
                    tone: .stop,
                    actionTitle: reason.requiresReconnect ? "去设置" : nil,
                    action: reason.requiresReconnect ? { router.go(.settings) } : nil
                )
                .padding(.horizontal, Theme.pageMargin)
            }

            VStack(alignment: .leading, spacing: Theme.gapS) {
                HStack(alignment: .firstTextBaseline) {
                    Text(statusLine)
                        .font(Theme.row.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.gapS)
                    NavPill(
                        title: store.filter.isActive
                            ? "筛选 · \(store.filter.activeChipLabels.count)"
                            : "筛选",
                        isProminent: store.filter.isActive
                    ) {
                        router.present(.queryFilter)
                    }
                }
                if let sub = statusSubline {
                    CaptionLine(text: sub)
                }
                if store.filter.isActive {
                    activeFilterChips
                }
                queryTable
            }
            .padding(.horizontal, Theme.pageMargin)
        }
    }

    private var activeFilterChips: some View {
        HStack(spacing: Theme.gapS) {
            ForEach(store.filter.activeChipLabels, id: \.self) { label in
                Text(label)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceMuted, in: Capsule())
            }
            Spacer(minLength: Theme.gapS)
            Button("重置") { store.resetFilter() }
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .minimumHitArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "筛选条件 " + store.filter.activeChipLabels.joined(separator: "，")
                + "，匹配 \(store.matchCount) 项，共 \(store.totalRowCount) 项"
        )
    }

    @ViewBuilder
    private var queryTable: some View {
        if store.visibleRows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                Text("没有符合条件的项")
                    .font(Theme.row)
                    .foregroundStyle(Theme.ink)
                Button("重置筛选") { store.resetFilter() }
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .minimumHitArea()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.rowPaddingH)
            .themedCard()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        QueryTableHeader()
                        ForEach(store.visibleRows) { row in
                            RowDivider()
                            QueryRowView(row: row) {
                                store.scrollAnchor = row.id
                                router.go(.queryDetail(row.id))
                            }
                            .id(row.id)
                        }
                    }
                    .themedCard()
                }
                .onAppear {
                    if let anchor = store.scrollAnchor {
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Bottom action bar

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: Theme.gapS) {
            if store.phase.hasResult {
                resultActions
            } else {
                if !viewModel.isConnected {
                    CaptionLine(text: "连接墨墨账号后可查阅")
                }
                PrimaryPillButton(
                    title: store.startActionCount > 0
                        ? "查阅 \(store.startActionCount) 项"
                        : "查阅",
                    isEnabled: viewModel.isConnected
                        && store.canStart
                        && !viewModel.isProviderLaneBusy
                ) {
                    startRun()
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

    @ViewBuilder
    private var resultActions: some View {
        if store.phase.isRunning {
            HStack(spacing: 12) {
                SecondaryPillButton(title: "修改") { store.requestInterrupt(.modify) }
                PrimaryPillButton(title: "停止") { store.stop() }
            }
        } else {
            HStack(spacing: 12) {
                SecondaryPillButton(title: "修改") { store.beginModify() }
                if store.hasUnfinishedWork {
                    PrimaryPillButton(
                        title: "继续查阅 · 其余 \(store.unfinishedRowCount) 项",
                        isEnabled: viewModel.isConnected && !viewModel.isProviderLaneBusy
                    ) {
                        resumeRun()
                    }
                } else {
                    PrimaryPillButton(
                        title: "复制当前 \(store.matchCount) 项",
                        isEnabled: store.matchCount > 0
                    ) {
                        copyMatches()
                    }
                }
            }
            if store.hasUnfinishedWork, store.matchCount > 0 {
                SecondaryPillButton(title: "复制当前 \(store.matchCount) 项") { copyMatches() }
            }
        }
    }

    // MARK: - Actions

    private func startRun() {
        guard let lease = viewModel.beginQueryRead() else { return }
        store.start(lease: lease)
    }

    private func resumeRun() {
        guard let lease = viewModel.beginQueryRead() else { return }
        store.resume(lease: lease)
    }

    private func copyMatches() {
        UIPasteboard.general.string = store.copyPayload
        let count = store.matchCount
        withAnimation { toastText = "已复制 \(count) 项" }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toastText = nil }
        }
    }

    // MARK: - Copy

    private var statusLine: String {
        switch store.phase {
        case .input:
            return ""
        case .resolving:
            return "正在定位 \(store.totalRowCount) 个词条…"
        case .reading:
            return "正在读取 \(store.completedRowCount)/\(store.totalRowCount)"
        case .completed:
            let unavailable = store.rows.count { $0.readStatus == .unavailable }
            return unavailable > 0
                ? "\(store.totalRowCount) 项 · 读取完成 · \(unavailable) 项含无法读取"
                : "\(store.totalRowCount) 项 · 读取完成"
        case let .stopped(reason):
            if case .globalFailure = reason { return reason.bannerTitle }
            return "已停止 · 已读 \(store.completedRowCount)/\(store.totalRowCount)"
        }
    }

    private var statusSubline: String? {
        if store.filter.isActive, store.phase.isRunning {
            return "匹配 \(store.matchCount) 项 · 已读 \(store.completedRowCount) 项 · "
                + "其余仍在读取，匹配数会更新"
        }
        if store.filter.isActive {
            return "匹配 \(store.matchCount) 项 / \(store.totalRowCount)"
        }
        if case .stopped = store.phase, store.unfinishedRowCount > 0 {
            return "其余 \(store.unfinishedRowCount) 项显示为「未读」"
        }
        return nil
    }

    private var interruptMessage: String {
        switch store.pendingInterrupt {
        case .modify:
            return "停止后已读取的 \(store.completedRowCount) 项保留，其余显示为「未读」。"
                + "修改文字后再查阅将从头开始。"
        case .back, nil:
            return "返回首页不会在后台继续读取。"
                + "停止后已读取的 \(store.completedRowCount) 项保留在本次会话中。"
        }
    }
}

// MARK: - Table

private struct QueryTableHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: 0) {
                Text("拼写")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(QueryContentFamily.allCases, id: \.self) { family in
                    Text(family.label).frame(width: 52)
                }
                Spacer().frame(width: 18)
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.vertical, 10)
            .accessibilityHidden(true)
        }
    }
}

/// One result row.
///
/// At accessibility sizes the four columns become a two-tier row — spelling on
/// the first line, labelled cells on the second — instead of truncating. The
/// whole row is one accessibility element, spoken spelling → 释义 → 例句 → 助记.
private struct QueryRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: QueryRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    twoTierLayout
                } else {
                    columnLayout
                }
            }
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.spelling)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(row.rowInability == nil ? "点按查看已返回内容" : "点按查看原因")
    }

    private var columnLayout: some View {
        HStack(spacing: 0) {
            Text(row.spelling)
                .font(Theme.row)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(QueryContentFamily.allCases, id: \.self) { family in
                QueryCellView(state: row.cell(family)).frame(width: 52)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18)
        }
    }

    private var twoTierLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.spelling)
                .font(Theme.row)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.gapM) {
                ForEach(QueryContentFamily.allCases, id: \.self) { family in
                    HStack(spacing: 4) {
                        Text(family.label)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                        QueryCellView(state: row.cell(family))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var accessibilityValue: String {
        var parts = QueryContentFamily.allCases.map { family in
            "\(family.label) \(spokenValue(row.cell(family)))"
        }
        if let reason = row.rowInability {
            parts.append("无法读取，\(reason.label)")
        }
        return parts.joined(separator: "，")
    }

    private func spokenValue(_ state: QueryCellState) -> String {
        switch state {
        case let .count(value):
            return "\(spelledOut(value))条"
        case .queued:
            return "排队中"
        case .loading:
            return "正在读取"
        case .unread:
            return "未读，未计入"
        case let .unavailable(reason):
            return "无法读取，\(reason.label)"
        }
    }

    /// Chinese numerals for 0–10 read far better than digits in VoiceOver.
    private func spelledOut(_ value: Int) -> String {
        let numerals = ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九", "十"]
        return numerals.indices.contains(value) ? numerals[value] : "\(value)"
    }
}

/// The frozen numeric grammar. Every state differs in glyph or text, never in
/// color alone: `0` is a quiet grey digit, `1+` is emphasized ink, and unread /
/// unavailable are words.
private struct QueryCellView: View {
    let state: QueryCellState

    var body: some View {
        switch state {
        case let .count(value):
            Text("\(value)")
                .font(Theme.digits)
                .fontWeight(value > 0 ? .semibold : .regular)
                .foregroundStyle(value > 0 ? Theme.ink : Theme.textSecondary)
        case .queued:
            Text("···")
                .font(Theme.digits)
                .foregroundStyle(Theme.textTertiary)
        case .loading:
            ProgressView().controlSize(.mini).tint(Theme.ink)
        case .unread:
            Text("未读")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        case .unavailable:
            Text("无法读取")
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.alert)
                .lineLimit(1)
                .minimumScaleFactor(1)
        }
    }
}

// MARK: - Filter sheet

struct QueryFilterSheet: View {
    @ObservedObject var store: QuerySessionStore
    let onDismiss: () -> Void

    @State private var draft = QueryFilter()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gapL) {
                    ForEach(QueryContentFamily.allCases, id: \.self) { family in
                        GroupedCard(title: family.label) {
                            SegmentControl(
                                values: QueryCountPredicate.allCases,
                                label: \.label,
                                selection: Binding(
                                    get: { draft.predicate(for: family) },
                                    set: { draft.setPredicate($0, for: family) }
                                )
                            )
                            .padding(Theme.rowPaddingH)
                        }
                    }

                    GroupedCard(title: "读取状态") {
                        VStack(spacing: 0) {
                            SegmentControl(
                                values: QueryReadStatusPredicate.allCases,
                                label: \.label,
                                selection: $draft.readStatus
                            )
                            .padding(Theme.rowPaddingH)

                            // Only reasons actually present in this batch.
                            if draft.readStatus == .unavailable,
                               !store.presentInabilityReasons.isEmpty {
                                ForEach(store.presentInabilityReasons, id: \.self) { reason in
                                    RowDivider()
                                    reasonRow(reason)
                                }
                            }
                        }
                    }

                    Text("匹配 \(matchCount) 项 / \(store.totalRowCount)")
                        .font(Theme.label)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.textInset)

                    Spacer(minLength: Theme.gapL)
                }
                .padding(.top, Theme.gapM)
            }
            .themedScreen()
            .navigationTitle("筛选条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("重置") { draft = .none }
                        .disabled(!draft.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(matchCount == store.totalRowCount ? "完成" : "完成 · 显示 \(matchCount) 项") {
                        store.setFilter(draft)
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear { draft = store.filter }
    }

    private var matchCount: Int { draft.apply(to: store.rows).count }

    private func reasonRow(_ reason: QueryInabilityReason) -> some View {
        Button {
            if draft.inabilityReasons.contains(reason) {
                draft.inabilityReasons.remove(reason)
            } else {
                draft.inabilityReasons.insert(reason)
            }
        } label: {
            HStack {
                Text(reason.label)
                    .font(Theme.row)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if draft.inabilityReasons.contains(reason) {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(minHeight: Theme.rowMinHeight)
            .padding(.horizontal, Theme.rowPaddingH)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(draft.inabilityReasons.contains(reason) ? "已选择" : "未选择")
    }
}

// MARK: - Detail

/// A row's read-only detail, rendered from already-returned objects.
///
/// It observes the same in-memory session, so a section fills in when its cell
/// completes — but opening it never triggers a request, and raw record IDs are
/// never shown.
struct QueryDetailView: View {
    @ObservedObject var store: QuerySessionStore
    let rowID: Int

    private var row: QueryRow? { store.row(withID: rowID) }
    private var detail: QueryRowDetail? { store.detail(forRowID: rowID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapL) {
                PageTitle(text: row?.spelling ?? "")
                    .padding(.horizontal, Theme.textInset)

                if let row, let reason = row.rowInability {
                    reasonPage(reason)
                } else if let row {
                    ForEach(QueryContentFamily.allCases, id: \.self) { family in
                        section(family, state: row.cell(family))
                    }
                    if store.phase.isRunning {
                        CaptionLine(text: "查阅仍在进行 · 本页随同一次读取自动更新，不另发请求")
                            .padding(.horizontal, Theme.textInset)
                    }
                    CaptionLine(
                        text: "来自刚才那次读取，不再发起新的请求；不可编辑、不保存、不显示原始 ID。"
                    )
                    .padding(.horizontal, Theme.textInset)
                }

                Spacer(minLength: Theme.gapL)
            }
            .padding(.top, Theme.gapS)
        }
        .themedScreen()
    }

    @ViewBuilder
    private func section(_ family: QueryContentFamily, state: QueryCellState) -> some View {
        GroupedCard(title: sectionTitle(family, state: state)) {
            switch state {
            case let .count(value) where value > 0:
                itemRows(family)
            case .count:
                CaptionLine(text: "已确认为 0 条，没有已返回的内容")
                    .padding(Theme.rowPaddingH)
            case .queued, .loading:
                CaptionLine(text: "正在读取…")
                    .padding(Theme.rowPaddingH)
            case .unread:
                CaptionLine(text: "未读 · 未计入匹配")
                    .padding(Theme.rowPaddingH)
            case let .unavailable(reason):
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason.label)
                        .font(Theme.body)
                        .foregroundStyle(Theme.alert)
                    Text("不计为 0，也不参与数值筛选")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.rowPaddingH)
            }
        }
    }

    private func sectionTitle(_ family: QueryContentFamily, state: QueryCellState) -> String {
        guard let count = state.knownCount else { return family.label }
        return "\(family.label) · \(count)"
    }

    @ViewBuilder
    private func itemRows(_ family: QueryContentFamily) -> some View {
        let detail = detail ?? QueryRowDetail()
        switch family {
        case .interpretation:
            ForEach(Array(detail.interpretations.enumerated()), id: \.offset) { index, record in
                if index > 0 { RowDivider() }
                itemBlock(
                    text: record.interpretation,
                    meta: [
                        record.tags.isEmpty ? nil : record.tags.joined(separator: " · "),
                        InterpretationPublicationStatus(providerStatus: record.status)?.label,
                    ]
                )
            }
        case .phrase:
            ForEach(Array(detail.phrases.enumerated()), id: \.offset) { index, record in
                if index > 0 { RowDivider() }
                itemBlock(
                    text: record.phrase,
                    meta: [
                        record.interpretation,
                        record.origin.isEmpty ? nil : record.origin,
                    ]
                )
            }
        case .note:
            ForEach(Array(detail.notes.enumerated()), id: \.offset) { index, record in
                if index > 0 { RowDivider() }
                itemBlock(text: record.note, meta: [record.noteType])
            }
        }
    }

    private func itemBlock(text: String, meta: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            let details = meta.compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.rowPaddingH)
    }

    /// A target-unavailable row explains what is known without fake counts.
    private func reasonPage(_ reason: QueryInabilityReason) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            GroupedCard(title: "已知") {
                CaptionLine(text: "原因：\(reason.label)。这是读取范围的限制，不代表墨墨里没有内容。")
                    .padding(Theme.rowPaddingH)
            }
            GroupedCard(title: "未知") {
                CaptionLine(text: "这个词的释义、例句与助记数量都无法安全读取，不显示任何数字。")
                    .padding(Theme.rowPaddingH)
            }
            GroupedCard(title: "可做") {
                CaptionLine(text: "确认拼写是否与墨墨中的词条一致，或稍后重新查阅。")
                    .padding(Theme.rowPaddingH)
            }
        }
    }
}
