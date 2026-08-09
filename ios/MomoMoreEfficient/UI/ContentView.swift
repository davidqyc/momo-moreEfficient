import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = CompanionViewModel()
    @State private var showingTokenSheet = false
    @State private var tokenDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section("批次释义") {
                    TextEditor(text: $viewModel.sourceText)
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("批次释义输入")
                }

                Section("主账号连接") {
                    HStack {
                        Text(viewModel.isConnected ? "已连接主账号" : "未连接")
                        Spacer()
                        if viewModel.isConnected {
                            Button("断开连接", role: .destructive) {
                                viewModel.disconnect()
                            }
                        } else {
                            Button("连接主账号") { showingTokenSheet = true }
                        }
                    }
                    Text("Token 仅保留在当前进程内存；进入后台后必须重新连接。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("预览") {
                        Task { await viewModel.previewCurrentInput() }
                    }
                    .disabled(!viewModel.isConnected || viewModel.isBusy)
                }

                if let preview = viewModel.preview {
                    Section("预览摘要") {
                        Text(
                            "新建 \(preview.counts.create) | 更新 \(preview.counts.update) | "
                                + "已一致 \(preview.counts.alreadyMatching) | 阻断 \(preview.counts.blocked)"
                        )
                    }

                    Section("逐项预览") {
                        ForEach(preview.rows) { row in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(row.spelling).font(.headline)
                                    Spacer()
                                    Text(row.classification.rawValue).font(.caption.bold())
                                }
                                if let current = row.current {
                                    Text("CURRENT").font(.caption).foregroundStyle(.secondary)
                                    Text(current)
                                }
                                Text("PROPOSED").font(.caption).foregroundStyle(.secondary)
                                Text(row.proposed)
                                if let reason = row.reason {
                                    Text(reason).font(.caption).foregroundStyle(.red)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Section("执行") {
                        Button("执行新建 \(preview.counts.create)", role: .destructive) {
                            viewModel.askToExecute(.create)
                        }
                        .disabled(preview.counts.create == 0 || viewModel.isBusy)
                        Button("执行更新 \(preview.counts.update)", role: .destructive) {
                            viewModel.askToExecute(.update)
                        }
                        .disabled(preview.counts.update == 0 || viewModel.isBusy)
                    }
                }

                Section("本次结果") {
                    Text(
                        "新建成功 \(viewModel.finalSummary.created) / "
                            + "更新成功 \(viewModel.finalSummary.updated) / "
                            + "已一致 \(viewModel.finalSummary.alreadyMatching) / "
                            + "失败 \(viewModel.finalSummary.failed) / "
                            + "未执行 \(viewModel.finalSummary.notAttempted)"
                    )
                    if let stoppedMessage = viewModel.finalSummary.stoppedMessage {
                        Text(stoppedMessage)
                            .foregroundStyle(.orange)
                    }
                    if let message = viewModel.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("释义录入伴侣")
            .overlay {
                if viewModel.isBusy { ProgressView("处理中…") }
            }
        }
        .sheet(isPresented: $showingTokenSheet, onDismiss: {
            tokenDraft.removeAll(keepingCapacity: false)
        }) {
            NavigationStack {
                Form {
                    SecureField("主账号 Token", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("请在确认登录目标主账号后手动粘贴。应用无法证明 Token 属于哪个账号。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("连接主账号")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingTokenSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("连接") {
                            viewModel.connect(token: &tokenDraft)
                            showingTokenSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
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
            if phase == .background { viewModel.enterBackground() }
        }
    }

    private var confirmationTitle: String {
        viewModel.pendingConfirmation == .update ? "确认更新现有自建释义？" : "确认新建自建释义？"
    }
}
