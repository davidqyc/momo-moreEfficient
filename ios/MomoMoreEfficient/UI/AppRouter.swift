import Foundation

/// Where a pushed destination takes the Owner.
///
/// One `write` destination on purpose (#161 correction A): the editor, the
/// Preview, the confirmation and the execution feedback are all *state inside*
/// that destination, and the active `ContentMode` stays owned by
/// `CompanionViewModel`. Switching 释义 ↔ 例句 on the work surface is therefore a
/// state change, never a navigation change, and `.write` can never appear twice
/// on the path.
///
/// Contextual History is different: `释义历史` and `例句历史` are genuinely
/// distinct child destinations, so `history` carries the mode it was entered
/// with and its presentation cannot drift from that mode.
enum AppRoute: Hashable {
    case write
    case history(ContentMode)
    case receipt(UUID)
    case query
    case queryDetail(Int)
    case settings
    case preferences
    case about
}

/// The one sheet that may be presented at a time.
enum AppSheet: Identifiable, Hashable {
    case connectToken
    case replaceToken
    case queryFilter

    var id: Self { self }
}

/// Navigation and presentation only.
///
/// This owns a `NavigationStack` path, one presented sheet, and nothing else.
/// It has no reference to a network client, a credential, a draft or a Query
/// result: destructive and interrupt dialogs stay bound to the store state that
/// actually knows whether they are warranted. Keeping it this small is what
/// stops it from becoming a router framework.
@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [AppRoute] = []
    @Published var sheet: AppSheet?

    init(path: [AppRoute] = [], sheet: AppSheet? = nil) {
        self.path = path
        self.sheet = sheet
    }

    var current: AppRoute? { path.last }

    func go(_ route: AppRoute) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToHome() {
        path.removeAll()
    }

    /// Replaces the whole path with a single destination.
    ///
    /// Capture uses this (`转到释义编辑` / `转到例句编辑`): the review is a modal
    /// over whatever was underneath, and accepting it must land on exactly one
    /// `.write` destination rather than pushing a second copy onto a stack that
    /// may already contain one.
    func replacePath(with route: AppRoute) {
        path = [route]
        sheet = nil
    }

    func present(_ sheet: AppSheet) {
        self.sheet = sheet
    }

    func dismissSheet() {
        sheet = nil
    }
}
