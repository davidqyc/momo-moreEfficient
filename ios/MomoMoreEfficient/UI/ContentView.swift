import SwiftUI

/// The deterministic boundary between app lifecycle and credential restoration.
///
/// An iOS 26 deferred App Intent starts in the background. View construction may
/// happen there, so it must never restore credentials. The intent installs its
/// review synchronously before the system's guaranteed foreground transition;
/// only an actually active scene is therefore allowed to restore a normal launch.
@MainActor
enum CaptureReviewForegroundGate {
    static func activate(
        sceneIsActive: Bool,
        captureReviewStore: CaptureReviewStore,
        viewModel: CompanionViewModel
    ) async {
        guard sceneIsActive else { return }
        if captureReviewStore.review != nil {
            viewModel.prepareForCaptureReview()
        } else {
            await viewModel.enterForeground()
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: CompanionViewModel
    @ObservedObject private var captureReviewStore: CaptureReviewStore
    @State private var showingTokenSheet = false
    @State private var tokenDraft = ""
    @State private var isSubmittingToken = false

    init(
        viewModel: @autoclosure @escaping () -> CompanionViewModel,
        captureReviewStore: CaptureReviewStore
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.captureReviewStore = captureReviewStore
    }

    var body: some View {
        NavigationStack {
            Group {
                if let review = captureReviewStore.review, !viewModel.isBusy {
                    captureReviewSurface(review)
                } else {
                    VStack(spacing: 0) {
                        rehearsalBanner
                        accountRow
                        modePicker
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
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle(
                isShowingCaptureReview
                    ? "检查捕获文本" : viewModel.contentMode.navigationTitle
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("关于")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("历史") {
                        HistoryListView(viewModel: viewModel)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isShowingCaptureReview {
                    captureReviewActionBar
                } else if viewModel.isShowingEditor {
                    previewActionBar
                } else if !viewModel.executionActions.isEmpty
                    || viewModel.canExecutePhrase
                    || viewModel.isExecuting {
                    executionBar
                }
            }
        }
        .sheet(isPresented: $showingTokenSheet, onDismiss: {
            clearTokenDraft()
            viewModel.clearTokenError()
        }) {
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
                Task { await activateCurrentSurface(sceneIsActive: true) }
            case .inactive, .background:
                viewModel.enterBackground()
            @unknown default:
                viewModel.enterBackground()
            }
        }
        .onReceive(captureReviewStore.$review) { review in
            if review != nil, !viewModel.isBusy {
                viewModel.prepareForCaptureReview()
            }
        }
        .onChange(of: viewModel.isBusy) { _, isBusy in
            if !isBusy, captureReviewStore.review != nil {
                viewModel.prepareForCaptureReview()
            }
        }
        .task {
            await activateCurrentSurface(sceneIsActive: scenePhase == .active)
        }
    }

    private var isShowingCaptureReview: Bool {
        captureReviewStore.review != nil && !viewModel.isBusy
    }

    private func captureReviewSurface(_ review: CaptureReviewStore.Review) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label("捕获检查 · 尚未预览", systemImage: "text.viewfinder")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Text("这一步不会读取 Token、访问墨墨、生成预览或授权写入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if review.replacedExistingReview {
                    Text("新的捕获文本已替换上一次待检查内容。")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            TextEditor(text: Binding(
                get: { captureReviewStore.review?.text ?? "" },
                set: { captureReviewStore.edit($0) }
            ))
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .autocorrectionDisabled()
            .accessibilityLabel("待检查的捕获文本")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.blue.opacity(0.45), lineWidth: 1)
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }

    private var captureReviewActionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button("转到释义编辑") { finishCaptureReview(in: .interpretation) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                Button("转到例句编辑") { finishCaptureReview(in: .phrase) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            Button("取消捕获", role: .cancel) { cancelCaptureReview() }
                .frame(maxWidth: .infinity)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func finishCaptureReview(in mode: ContentMode) {
        guard let text = captureReviewStore.takeReviewedText() else { return }
        viewModel.acceptCapturedText(text, in: mode)
        Task { await viewModel.enterForeground() }
    }

    private func cancelCaptureReview() {
        captureReviewStore.cancel()
        Task { await viewModel.enterForeground() }
    }

    private func activateCurrentSurface(sceneIsActive: Bool) async {
        await CaptureReviewForegroundGate.activate(
            sceneIsActive: sceneIsActive,
            captureReviewStore: captureReviewStore,
            viewModel: viewModel
        )
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
            if viewModel.isConnected {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                    Text("已连接")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("已连接")
            } else {
                Text("未连接")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
                .font(.subheadline)
                .disabled(viewModel.isBusy)
            } else {
                Button("连接") { showingTokenSheet = true }
                    .font(.subheadline)
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

    /// The editor is the primary work surface: it fills all vertical space
    /// between the mode picker and the pinned Preview action.
    private var editorSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let acknowledgement = viewModel.completionAcknowledgement {
                Text(acknowledgement)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.sourceText)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(viewModel.contentMode.editorAccessibilityLabel)
                if viewModel.sourceText.isEmpty {
                    Text(viewModel.contentMode.editorHint)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 14)
                        .padding(.leading, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            )

            if let parseMessage = viewModel.localParseState.message {
                Text(parseMessage)
                    .font(.footnote)
                    .foregroundStyle(viewModel.localParseState.isValid ? Color.secondary : Color.red)
            }

            feedbackView
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func previewSurface(_ preview: PreviewPresentation) -> some View {
        List {
            Section {
                previewHeaderRow(
                    count: preview.rows.count,
                    unit: "条释义",
                    first: preview.rows.first?.spelling,
                    last: preview.rows.last?.spelling
                )
                HStack(spacing: 14) {
                    summaryLabel("新建", preview.counts.create, color: .accentColor)
                    summaryLabel("更新", preview.counts.update, color: .orange)
                    summaryLabel("一致", preview.counts.alreadyMatching, color: .secondary, emphasized: false)
                    summaryLabel("阻断", preview.counts.blocked, color: .red)
                }
                Text(viewModel.selectedTagsSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                stalePreviewRow
                feedbackView
            }

            Section {
                ForEach(preview.rows) { row in
                    previewRow(row)
                        .listRowBackground(
                            row.classification == .blocked
                                ? Color(.systemRed).opacity(0.07) : nil
                        )
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func phrasePreviewSurface(_ preview: PhrasePreviewPresentation) -> some View {
        List {
            Section {
                previewHeaderRow(
                    count: preview.rows.count,
                    unit: "条例句",
                    first: preview.rows.first?.spelling,
                    last: preview.rows.last?.spelling
                )
                HStack(spacing: 14) {
                    summaryLabel("新建", preview.createCount, color: .accentColor)
                    summaryLabel("一致", preview.alreadyMatchingCount, color: .secondary, emphasized: false)
                    summaryLabel("阻断", preview.blockedCount, color: .red)
                }
                Text(viewModel.selectedTagsSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                stalePreviewRow
                feedbackView
            }

            Section {
                ForEach(preview.rows) { row in
                    phrasePreviewRow(row)
                        .listRowBackground(
                            row.classification == .blocked
                                ? Color(.systemRed).opacity(0.07) : nil
                        )
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func previewHeaderRow(
        count: Int,
        unit: String,
        first: String?,
        last: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(count) \(unit)")
                .font(.headline)
            if let first, let last {
                Text("\(first) → \(last)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("编辑") { viewModel.editInput() }
                .font(.subheadline)
                .buttonStyle(.borderless)
                .disabled(viewModel.isBusy)
        }
    }

    @ViewBuilder
    private var stalePreviewRow: some View {
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
                .buttonStyle(.borderless)
                .disabled(
                    !viewModel.isConnected
                        || !viewModel.localParseState.isValid
                        || viewModel.isBusy
                )
            }
            .listRowBackground(Color(.systemOrange).opacity(0.12))
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
                        .font(.subheadline)
                        .fontWeight(row.classification == .blocked ? .semibold : .regular)
                        .foregroundStyle(phraseClassificationColor(row.classification))
                    Image(systemName: viewModel.expandedRowIDs.contains(row.id)
                        ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let reason = row.blockedReason {
                Text(reason)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }

            if row.classification == .alreadyMatching, !row.observations.isEmpty {
                Text(phraseObservationLabel(row.observations))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.expandedRowIDs.contains(row.id) {
                VStack(alignment: .leading, spacing: 10) {
                    detailLabel("EN", row.english)
                    detailLabel("ZH", row.chinese)
                    detailLabel("SOURCE", row.source ?? "未填写", secondaryValue: true)
                }
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
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
                        .font(.subheadline)
                        .fontWeight(row.classification == .blocked ? .semibold : .regular)
                        .foregroundStyle(classificationColor(row.classification))
                    if row.canExpand {
                        Image(systemName: viewModel.expandedRowIDs.contains(row.id)
                            ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.canExpand)

            if let reason = row.compactBlockedReason {
                Text(reason)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }

            if let details = viewModel.details(for: row) {
                VStack(alignment: .leading, spacing: 10) {
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
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
    }

    /// The single bottom action while the editor is the working surface: the
    /// Preview button, or its disabled in-progress form while a Preview reads.
    private var previewActionBar: some View {
        Button {
            Task { await viewModel.previewCurrentInput() }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isPreviewing {
                    ProgressView()
                    Text(previewLoadingTitle)
                } else {
                    Text("预览")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            !viewModel.isConnected
                || !viewModel.localParseState.isValid
                || viewModel.isBusy
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var executionBar: some View {
        Group {
            if viewModel.isExecuting {
                executionProgressRow
            } else if viewModel.contentMode == .phrase {
                Button {
                    viewModel.askToExecutePhrase()
                } label: {
                    Text("新建 \(viewModel.phrasePreview?.createCount ?? 0) 条例句")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canExecutePhrase)
            } else {
                HStack(spacing: 12) {
                    ForEach(viewModel.executionActions) { action in
                        Button {
                            if action.coversWholePlan {
                                viewModel.askToExecuteWholePlan()
                            } else if let group = action.group {
                                viewModel.askToExecute(group)
                            }
                        } label: {
                            Text(action.title)
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(action.group == .update ? .orange : .blue)
                        .disabled(action.count == 0 || viewModel.isBusy)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var executionProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                Text(viewModel.executionProgressLabel ?? "正在执行…")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                Color(.systemFill),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            Text("短暂切换应用不会取消；若系统回收后台时间，将安全停止。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        SecureField("墨墨账号 Token", text: $tokenDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        VStack(spacing: 2) {
                            PasteButton(payloadType: String.self) { pastedStrings in
                                guard let pastedToken = pastedStrings.first else { return }
                                tokenDraft = pastedToken
                            }
                            .accessibilityLabel("粘贴 Token")

                            Text("粘贴 Token")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    if tokenValidationIsInFlight {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在验证…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("正在验证 Token")
                    }
                    if let message = viewModel.tokenErrorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("个人 Token")
                } footer: {
                    Text("这是你自己的墨墨 API Token。")
                }

                Section {
                    Text("墨墨 App → 我的 → 更多设置 → 实验功能 → 开放 API")
                        .font(.subheadline.weight(.medium))
                } header: {
                    Text("获取方式")
                } footer: {
                    Text("请先登录你准备操作的墨墨账号，再获取并手动粘贴 Token。小黑鸟伴侣无法独立证明一个手动提供的 Token 属于哪个账号。")
                }

                Section {
                    Text("Token 只保存在这台 iPhone 的设备本地 Keychain 中，不会上传给开发者或任何项目服务器。选择“移除 Token”（断开连接）会删除本机保存的 Token。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("只保存在本机")
                }

                Section {
                } footer: {
                    Text("小黑鸟伴侣是兼容墨墨的独立第三方工具，不是墨墨官方应用。")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .navigationTitle(viewModel.isConnected ? "更换 Token" : "连接墨墨账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        viewModel.clearTokenError()
                        showingTokenSheet = false
                    }
                    .disabled(tokenValidationIsInFlight)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isConnected ? "更换" : "连接") {
                        // Synchronous UI latch: Cancel/dismiss is closed before
                        // the async Task gets its first MainActor turn.
                        isSubmittingToken = true
                        Task {
                            let connected = await viewModel.connect(token: tokenDraft)
                            isSubmittingToken = false
                            if connected {
                                clearTokenDraft()
                                showingTokenSheet = false
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(tokenDraft.isEmpty || tokenValidationIsInFlight)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(tokenValidationIsInFlight)
    }

    private var tokenValidationIsInFlight: Bool {
        isSubmittingToken || viewModel.isValidatingCredential
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

    private func summaryLabel(
        _ title: String,
        _ value: Int,
        color: Color,
        emphasized: Bool = true
    ) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Text("\(value)")
        }
        .font(.subheadline.monospacedDigit())
        .fontWeight(emphasized && value > 0 ? .semibold : .regular)
        .foregroundStyle(value > 0 ? color : .secondary)
    }

    private func detailLabel(
        _ title: String,
        _ value: String,
        secondaryValue: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .lineSpacing(2)
                .foregroundStyle(secondaryValue ? Color.secondary : Color.primary)
                .textSelection(.enabled)
        }
    }

    private func classificationColor(_ classification: PreviewClassification) -> Color {
        switch classification {
        case .create: return .accentColor
        case .update: return .orange
        case .alreadyMatching: return .secondary
        case .blocked: return .red
        }
    }

    private func phraseClassificationColor(_ classification: PhrasePreviewClassification) -> Color {
        switch classification {
        case .create: return .accentColor
        case .alreadyMatching: return .secondary
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

private struct AboutView: View {
    private let privacyURL = URL(
        string: "https://github.com/davidqyc/momo-moreEfficient/blob/main/PRIVACY.md"
    )!
    private let supportURL = URL(
        string: "https://github.com/davidqyc/momo-moreEfficient/issues"
    )!

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("小黑鸟伴侣")
                        .font(.headline)
                    Text("把你准备好的释义和例句安全录入墨墨。")
                }
                .padding(.vertical, 2)
            } footer: {
                Text("小黑鸟伴侣是兼容墨墨的独立第三方工具，不是墨墨官方应用。")
            }

            Section {
                Link("隐私说明", destination: privacyURL)
                Link("项目与反馈", destination: supportURL)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ImportPreferencesView: View {
    @ObservedObject var viewModel: CompanionViewModel

    var body: some View {
        List {
            Section {
                LabeledContent("发布", value: "公开")
            }

            Section {
                ForEach(viewModel.availableWriteTags, id: \.self) { tag in
                    Button {
                        viewModel.toggleTag(tag)
                    } label: {
                        HStack {
                            // Concrete Color.primary: the hierarchical .primary would
                            // resolve against the row button's tint and render blue.
                            Text(tag)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if viewModel.isTagSelected(tag) {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(viewModel.isBusy)
                    .accessibilityValue(viewModel.isTagSelected(tag) ? "已选择" : "未选择")
                }
            } header: {
                HStack {
                    Text("标签 · 可选")
                    Spacer()
                    Text("已选 \(viewModel.selectedTags.count) / 最多 \(WriteTagPreference.maximumSelectionCount)")
                        .monospacedDigit()
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
                .tint(.red)
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
            Text("\(receipt.contentKind.displayLabel) · \(operation) \(receipt.items.count) · \(spellingSummary)")
                .font(.body)
                .lineLimit(1)
            (
                Text("\(receipt.timestamp.formatted(date: .omitted, time: .shortened)) · ")
                    .foregroundStyle(.secondary)
                    + Text(outcomeSummary)
                    .foregroundStyle(outcomeColor)
            )
            .font(.footnote)
        }
        .padding(.vertical, 2)
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

    private var outcomeColor: Color {
        if receipt.isFullSuccess { return .green }
        return receipt.failed > 0 ? .red : .orange
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
