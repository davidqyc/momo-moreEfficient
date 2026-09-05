import SwiftUI

/// The deterministic boundary between app lifecycle and credential restoration.
///
/// An iOS 26 deferred App Intent starts in the background. View construction may
/// happen there, so it must never restore credentials. The intent installs its
/// review synchronously before the system's guaranteed foreground transition;
/// only an actually active scene is therefore allowed to restore a normal launch.
@MainActor
enum CaptureReviewForegroundGate {
    enum Result: Equatable {
        case inactive
        case deferredBusy
        case reviewReady
        case restoredNormally
        case inboxFailure(PendingCaptureInboxError)
    }

    @discardableResult
    static func activate(
        sceneIsActive: Bool,
        captureReviewStore: CaptureReviewStore,
        captureInbox: () throws -> PendingCaptureInbox = {
            try PendingCaptureInbox.appGroup()
        },
        viewModel: CompanionViewModel
    ) async -> Result {
        guard sceneIsActive else { return .inactive }
        // An already-authorized operation owns the current lifecycle. Do not even
        // claim the durable share file until the operation reaches a safe idle.
        guard !viewModel.isBusy else { return .deferredBusy }

        do {
            let inbox = try captureInbox()
            if try inbox.consume(install: { capture in
                captureReviewStore.receive(
                    capture.text,
                    sourceURL: capture.sourceURL,
                    sourceTitle: capture.sourceTitle,
                    capturedAt: capture.capturedAt
                )
            }) != nil {
                viewModel.prepareForCaptureReview()
                return .reviewReady
            }
        } catch let error as PendingCaptureInboxError {
            return .inboxFailure(error)
        } catch {
            return .inboxFailure(.ioFailure)
        }

        if captureReviewStore.review != nil {
            viewModel.prepareForCaptureReview()
            return .reviewReady
        } else {
            await viewModel.enterForeground()
            return .restoredNormally
        }
    }
}

/// The application root.
///
/// It keeps the responsibilities the retrofit must not move: the one
/// `CompanionViewModel`, the scenePhase ordering, the Capture pickup gate, the
/// pending-inbox alert and every write confirmation. What it gained is a
/// data-driven `NavigationStack` path and an app-scoped `QuerySessionStore`
/// living *above* the Query destination, so leaving and re-entering 批量查阅
/// restores the result without a request.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: CompanionViewModel
    @StateObject private var router = AppRouter()
    @StateObject private var queryStore = QuerySessionStore()
    @ObservedObject private var captureReviewStore: CaptureReviewStore
    private let captureInbox: () throws -> PendingCaptureInbox
    @State private var captureInboxErrorMessage: String?

    init(
        viewModel: @autoclosure @escaping () -> CompanionViewModel,
        captureReviewStore: CaptureReviewStore,
        captureInbox: @escaping () throws -> PendingCaptureInbox = {
            try PendingCaptureInbox.appGroup()
        }
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.captureReviewStore = captureReviewStore
        self.captureInbox = captureInbox
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView(
                onEnterWrite: { mode in
                    // The mode is view-model state; the route is the one
                    // `.write` destination.
                    viewModel.selectMode(mode)
                    router.go(.write)
                },
                onEnterQuery: { router.go(.query) },
                onOpenSettings: { router.go(.settings) }
            )
            .navigationBarHidden(true)
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            BackCircleButton { back(from: route) }
                        }
                    }
                    .navigationBarBackButtonHidden(true)
            }
        }
        .tint(Theme.ink)
        .overlay {
            if let review = captureReviewStore.review, !viewModel.isBusy {
                CaptureReviewView(
                    captureReviewStore: captureReviewStore,
                    review: review,
                    onAccept: finishCaptureReview,
                    onCancel: cancelCaptureReview
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { rehearsalBanner }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .connectToken:
                TokenSheet(viewModel: viewModel, isReplacement: false) {
                    router.dismissSheet()
                }
            case .replaceToken:
                TokenSheet(viewModel: viewModel, isReplacement: true) {
                    router.dismissSheet()
                }
            case .queryFilter:
                QueryFilterSheet(store: queryStore) { router.dismissSheet() }
            }
        }
        .modifier(WriteConfirmationDialogs(viewModel: viewModel))
        .alert(
            "无法读取共享内容",
            isPresented: Binding(
                get: { captureInboxErrorMessage != nil },
                set: { if !$0 { captureInboxErrorMessage = nil } }
            )
        ) {
            Button("移除共享内容", role: .destructive) { removePendingCapture() }
            Button("保留", role: .cancel) {}
        } message: {
            Text(captureInboxErrorMessage ?? "")
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
            if !isBusy {
                Task { await activateCurrentSurface(sceneIsActive: scenePhase == .active) }
            }
        }
        // A real account identity change — a successful connect, replacement or
        // removal — clears account-derived Query truth while keeping the input.
        .onChange(of: viewModel.accountIdentity) { _, identity in
            queryStore.handleAccountIdentityChange(to: identity)
        }
        .task {
            queryStore.handleAccountIdentityChange(to: viewModel.accountIdentity)
            await activateCurrentSurface(sceneIsActive: scenePhase == .active)
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .write:
            WriteSurfaceView(viewModel: viewModel, router: router)
        case let .history(mode):
            HistoryListView(viewModel: viewModel, router: router, mode: mode)
        case let .receipt(id):
            if let receipt = viewModel.history.first(where: { $0.id == id }) {
                HistoryDetailView(receipt: receipt)
            } else {
                CaptionLine(text: "暂无历史").themedScreen()
            }
        case .query:
            QueryView(viewModel: viewModel, store: queryStore, router: router)
        case let .queryDetail(rowID):
            QueryDetailView(store: queryStore, rowID: rowID)
        case .settings:
            SettingsRootView(viewModel: viewModel, router: router)
        case .preferences:
            PreferencesView(viewModel: viewModel)
        case .about:
            AboutPageView()
        }
    }

    /// Back is intercepted only where leaving would silently abandon running
    /// work: a running Query asks first, and nothing continues in the background.
    private func back(from route: AppRoute) {
        if route == .query, queryStore.phase.isRunning {
            queryStore.requestInterrupt(.back)
            return
        }
        router.pop()
    }

    // MARK: - Capture

    private func finishCaptureReview(in mode: ContentMode) {
        guard let text = captureReviewStore.takeReviewedText() else { return }
        viewModel.acceptCapturedText(text, in: mode)
        // Replace the path so `.write` is present exactly once, whatever the
        // Owner had open when the capture arrived.
        router.replacePath(with: .write)
        Task { await activateCurrentSurface(sceneIsActive: scenePhase == .active) }
    }

    private func cancelCaptureReview() {
        captureReviewStore.cancel()
        Task { await activateCurrentSurface(sceneIsActive: scenePhase == .active) }
    }

    private func activateCurrentSurface(sceneIsActive: Bool) async {
        let result = await CaptureReviewForegroundGate.activate(
            sceneIsActive: sceneIsActive,
            captureReviewStore: captureReviewStore,
            captureInbox: captureInbox,
            viewModel: viewModel
        )
        switch result {
        case let .inboxFailure(error):
            captureInboxErrorMessage = error.localizedDescription
        case .reviewReady, .restoredNormally:
            captureInboxErrorMessage = nil
        case .inactive, .deferredBusy:
            break
        }
    }

    private func removePendingCapture() {
        do {
            try captureInbox().removePending()
            captureInboxErrorMessage = nil
            Task { await activateCurrentSurface(sceneIsActive: scenePhase == .active) }
        } catch {
            captureInboxErrorMessage = "移除失败：暂时无法访问共享空间。可稍后重试，或保留。"
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
                .allowsHitTesting(false)
        }
    }
}

/// The three write confirmations, unchanged.
///
/// They stay at the root and stay bound to the view model's armed approval, so
/// the Preview-is-not-authorization rule is exactly what it was: one native
/// destructive confirmation, armed to one snapshot, consumed once.
private struct WriteConfirmationDialogs: ViewModifier {
    @ObservedObject var viewModel: CompanionViewModel

    func body(content: Content) -> some View {
        content
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
                // One approval, stating the total, both memberships and the digest
                // that commits it to this exact Preview and to both subplans.
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
    }

    private var confirmationTitle: String {
        viewModel.pendingConfirmation == .update ? "确认更新现有自建释义？" : "确认新建自建释义？"
    }
}
