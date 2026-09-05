import SwiftUI

/// The Capture review surface.
///
/// The visual moved into 墨与米; the proven lifecycle did not. Storage, the App
/// Group inbox, the pickup gate and the scenePhase ordering all stay where they
/// were — this view only presents what `CaptureReviewStore` already holds. It
/// reads no Token, contacts no provider, generates no Preview and authorizes no
/// write, and the three accessibility identifiers physical- and simulator-device
/// regression tests address are preserved verbatim through
/// `CaptureAccessibilityIdentifier`.
struct CaptureReviewView: View {
    @ObservedObject var captureReviewStore: CaptureReviewStore
    let review: CaptureReviewStore.Review
    let onAccept: (ContentMode) -> Void
    let onCancel: () -> Void

    private var trimmedText: String {
        review.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEmpty: Bool { trimmedText.isEmpty }

    var body: some View {
        // A modal over whatever was underneath, with its own bar rather than a
        // back control: the review is answered, not navigated away from. The
        // `抓词` title and the nav-bar 取消 are the shape existing physical- and
        // simulator-device regression tests already drive.
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                header
                editor
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.top, Theme.gapM)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedScreen()
            .navigationTitle("抓词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel, action: onCancel)
                        .accessibilityIdentifier(
                            CaptureAccessibilityIdentifier.cancelButton
                        )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        }
        .tint(Theme.ink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.viewfinder")
                    .font(.footnote)
                Text("抓词 · 尚未预览")
                    .font(Theme.row.weight(.semibold))
                if review.isEdited {
                    Text("已编辑")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceMuted, in: Capsule())
                }
            }
            .foregroundStyle(Theme.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(CaptureAccessibilityIdentifier.status)

            Text("这一步不会读取 Token、访问墨墨、生成预览或授权写入。")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if review.replacedExistingReview {
                Text("新的抓词内容已替换上一次内容。")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.alert)
            }

            if let sourceURL = review.sourceURL {
                let title = review.sourceTitle.map { "\($0) · " } ?? ""
                Text("来源：\(title)\(sourceURL.absoluteString)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
    }

    private var editor: some View {
        TextEditor(text: Binding(
            get: { captureReviewStore.review?.text ?? "" },
            set: { captureReviewStore.edit($0) }
        ))
        .font(Theme.row)
        .foregroundStyle(Theme.ink)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .autocorrectionDisabled()
        .accessibilityLabel("抓词内容")
        .accessibilityIdentifier(CaptureAccessibilityIdentifier.textEditor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedCard()
    }

    private var actionBar: some View {
        VStack(spacing: Theme.gapS) {
            if isEmpty {
                CaptionLine(text: "内容为空 · 输入或粘贴后才能转到编辑")
            }
            HStack(spacing: 10) {
                PrimaryPillButton(title: "转到释义编辑", isEnabled: !isEmpty) {
                    onAccept(.interpretation)
                }
                PrimaryPillButton(title: "转到例句编辑", isEnabled: !isEmpty) {
                    onAccept(.phrase)
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
}
