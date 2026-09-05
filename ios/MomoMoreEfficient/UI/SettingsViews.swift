import SwiftUI

/// 设置 — the one account-management surface.
///
/// Work surfaces show a read-only `连接状态` line and never duplicate Token or
/// preference controls. Account management and 录入偏好 are unavailable while an
/// authorized write is executing, with a truthful reason.
struct SettingsRootView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var router: AppRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapL) {
                PageTitle(text: "设置")
                    .padding(.horizontal, Theme.textInset)

                if let acknowledgement = viewModel.credentialAcknowledgement {
                    AckLine(text: acknowledgement)
                        .padding(Theme.rowPaddingH)
                        .themedCard(radius: Theme.radiusBanner)
                        .padding(.horizontal, Theme.pageMargin)
                }

                accountGroup

                GroupedCard(title: "录入") {
                    GroupedRow(
                        label: "录入偏好",
                        showsChevron: true,
                        action: isBusy ? nil : { router.go(.preferences) }
                    ) {
                        RowValue(text: viewModel.writePreferenceSummary)
                    }
                    .opacity(isBusy ? 0.5 : 1)
                }

                GroupedCard(
                    title: "关于",
                    footnote: "小黑鸟伴侣是兼容墨墨的独立第三方工具，不是墨墨官方应用。\n"
                        + "版本 \(DiagnosticEnvironment.current.appVersionAndBuild)"
                ) {
                    GroupedRow(
                        label: "关于小黑鸟伴侣",
                        showsChevron: true,
                        action: { router.go(.about) }
                    )
                }

                if isBusy {
                    CaptionLine(text: "写入执行中 · 完成后可管理账号与偏好")
                        .padding(.horizontal, Theme.textInset)
                }

                Spacer(minLength: Theme.gapL)
            }
            .padding(.top, Theme.gapS)
        }
        .themedScreen()
        .confirmationDialog(
            "移除本机保存的 Token？",
            isPresented: Binding(
                get: { viewModel.isPendingTokenRemoval },
                set: { if !$0 { viewModel.cancelTokenRemoval() } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除 Token", role: .destructive) { viewModel.confirmRemoveToken() }
            Button("取消", role: .cancel) { viewModel.cancelTokenRemoval() }
        } message: {
            Text(
                "只删除这台 iPhone 上保存的 Token 并断开连接。"
                    + "不会删除墨墨账号里的任何数据，也不会清除本机历史与草稿。"
            )
        }
    }

    private var isBusy: Bool { viewModel.isBusy }

    @ViewBuilder
    private var accountGroup: some View {
        GroupedCard(
            title: "墨墨账号",
            footnote: "Token 只保存在这台 iPhone 的本地 Keychain 中，"
                + "不会上传给开发者或任何项目服务器。移除 Token 即断开连接。"
        ) {
            if viewModel.isConnected {
                GroupedRow(label: "连接状态") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink)
                        Text("已连接")
                            .font(Theme.rowValue)
                            .foregroundStyle(Theme.ink)
                    }
                }
                RowDivider()
                GroupedRow(
                    label: "更换 Token",
                    showsChevron: true,
                    action: isBusy ? nil : { router.present(.replaceToken) }
                )
                .opacity(isBusy ? 0.5 : 1)
                RowDivider()
                GroupedRow(
                    label: "移除 Token",
                    isDestructive: true,
                    action: isBusy ? nil : { viewModel.askToRemoveToken() }
                )
                .opacity(isBusy ? 0.5 : 1)
            } else {
                GroupedRow(label: "连接状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .strokeBorder(Theme.textSecondary, lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                        Text("未连接")
                            .font(Theme.rowValue)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                RowDivider()
                GroupedRow(
                    label: "连接墨墨账号",
                    showsChevron: true,
                    action: isBusy ? nil : { router.present(.connectToken) }
                )
                .opacity(isBusy ? 0.5 : 1)
            }

            if let message = viewModel.tokenRemovalErrorMessage {
                RowDivider()
                ErrorLine(text: message)
                    .padding(Theme.rowPaddingH)
            }
        }
    }
}

/// 录入偏好 — one page, two sections (correction 1).
struct PreferencesView: View {
    @ObservedObject var viewModel: CompanionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapL) {
                PageTitle(text: "录入偏好")
                    .padding(.horizontal, Theme.textInset)

                GroupedCard(
                    title: "释义发布状态",
                    footnote: "「未发布」是墨墨开放 API 的状态名称；"
                        + "此偏好仅适用于释义，例句与助记没有发布选项。"
                ) {
                    VStack(alignment: .leading, spacing: Theme.gapS) {
                        SegmentControl(
                            values: InterpretationPublicationStatus.allCases,
                            label: \.label,
                            selection: Binding(
                                get: { viewModel.publicationPreference },
                                set: { viewModel.selectPublicationPreference($0) }
                            ),
                            isEnabled: !viewModel.isBusy
                        )
                    }
                    .padding(Theme.rowPaddingH)
                }

                GroupedCard(
                    title: "标签（释义、例句共用）· 可选",
                    footnote: viewModel.tagSelectionHint
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(viewModel.tagSummaryLine)
                                .font(Theme.label)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Theme.gapS)
                            Text("已选 \(viewModel.selectedTags.count) / 3")
                                .font(Theme.label)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, Theme.rowPaddingH)
                        .padding(.top, Theme.gapM)

                        TagChipGrid(
                            tags: viewModel.availableWriteTags,
                            isSelected: viewModel.isTagSelected,
                            canToggle: viewModel.canToggleTag,
                            toggle: viewModel.toggleTag,
                            isEnabled: !viewModel.isBusy
                        )
                    }
                }

                if let message = viewModel.errorMessage {
                    ErrorLine(text: message)
                        .padding(.horizontal, Theme.textInset)
                }

                Spacer(minLength: Theme.gapL)
            }
            .padding(.top, Theme.gapS)
        }
        .themedScreen()
    }
}

/// 关于小黑鸟伴侣. Both links leave the app through the system browser.
struct AboutPageView: View {
    private let privacyURL = URL(
        string: "https://github.com/davidqyc/momo-moreEfficient/blob/main/PRIVACY.md"
    )!
    private let supportURL = URL(
        string: "https://github.com/davidqyc/momo-moreEfficient/issues"
    )!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapL) {
                PageTitle(text: "关于")
                    .padding(.horizontal, Theme.textInset)

                GroupedCard(
                    footnote: "小黑鸟伴侣是兼容墨墨的独立第三方工具，不是墨墨官方应用。"
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("小黑鸟伴侣")
                            .font(Theme.row.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("把你准备好的释义和例句安全录入墨墨。")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.rowPaddingH)
                }

                GroupedCard {
                    externalLinkRow("隐私说明", url: privacyURL)
                    RowDivider()
                    externalLinkRow("项目与反馈", url: supportURL)
                }

                Spacer(minLength: Theme.gapL)
            }
            .padding(.top, Theme.gapS)
        }
        .themedScreen()
    }

    private func externalLinkRow(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title)
                    .font(Theme.row)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(minHeight: Theme.rowMinHeight)
            .padding(.horizontal, Theme.rowPaddingH)
            .contentShape(Rectangle())
        }
        .accessibilityHint("在系统浏览器中打开")
    }
}

/// The connect / replace Token sheet.
///
/// One view, two titles. Replacement always starts from a blank secure field:
/// the saved Token is never displayed or prefilled, and the candidate only
/// becomes active after an independent authenticated validation *and* a
/// successful Keychain save.
struct TokenSheet: View {
    @ObservedObject var viewModel: CompanionViewModel
    let isReplacement: Bool
    let onDismiss: () -> Void

    @State private var tokenDraft = ""
    @State private var isSubmittingToken = false

    private var validationIsInFlight: Bool {
        isSubmittingToken || viewModel.isValidatingCredential
    }

    var body: some View {
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
                    if validationIsInFlight {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在验证…")
                            if isReplacement {
                                Text("· 原连接仍在使用中")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("正在验证 Token")
                    }
                    if let message = viewModel.tokenErrorMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Theme.alert)
                            if isReplacement {
                                Text("新 Token 未生效 · 原连接保持")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                    }
                } header: {
                    Text("个人 Token")
                } footer: {
                    if isReplacement {
                        Text("不会显示已保存的 Token。新 Token 只有通过墨墨验证后才会替换当前连接。")
                    } else {
                        Text("这是你自己的墨墨 API Token。")
                    }
                }

                Section {
                    Text("墨墨 App → 我的 → 更多设置 → 实验功能 → 开放 API")
                        .font(.subheadline.weight(.medium))
                } header: {
                    Text("获取方式")
                } footer: {
                    Text(
                        "请先登录你准备操作的墨墨账号，再获取并手动粘贴 Token。"
                            + "小黑鸟伴侣无法独立证明一个手动提供的 Token 属于哪个账号。"
                    )
                }

                Section {
                    Text(
                        "Token 只保存在这台 iPhone 的设备本地 Keychain 中，"
                            + "不会上传给开发者或任何项目服务器。选择“移除 Token”（断开连接）会删除本机保存的 Token。"
                    )
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
            .navigationTitle(isReplacement ? "更换 Token" : "连接墨墨账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        viewModel.clearTokenError()
                        clearTokenDraft()
                        onDismiss()
                    }
                    .disabled(validationIsInFlight)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isReplacement ? "更换" : "连接") {
                        // Synchronous UI latch: Cancel/dismiss is closed before
                        // the async Task gets its first MainActor turn.
                        isSubmittingToken = true
                        Task {
                            let connected = await viewModel.connect(token: tokenDraft)
                            isSubmittingToken = false
                            if connected {
                                clearTokenDraft()
                                onDismiss()
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(tokenDraft.isEmpty || validationIsInFlight)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(validationIsInFlight)
    }

    private func clearTokenDraft() {
        tokenDraft.removeAll(keepingCapacity: false)
    }
}
