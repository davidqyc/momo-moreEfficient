import UIKit

final class ShareViewController: UIViewController {
    private let textView = UITextView()
    private let sourceLabel = UILabel()
    private let statusLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var sourceURL: URL?
    private var sourceTitle: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        Task { await loadSharedPayload() }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "保存到小黑鸟伴侣"
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.borderWidth = 1
        textView.layer.cornerRadius = 10
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.accessibilityLabel = "待保存的共享文本"

        sourceLabel.font = .preferredFont(forTextStyle: .footnote)
        sourceLabel.textColor = .secondaryLabel
        sourceLabel.numberOfLines = 2
        sourceLabel.isHidden = true

        statusLabel.text = "正在读取共享文本…"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        saveButton.setTitle("保存", for: .normal)
        saveButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        saveButton.isEnabled = false
        saveButton.addTarget(self, action: #selector(saveCapture), for: .touchUpInside)

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelCapture), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, saveButton])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 12

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            textView,
            sourceLabel,
            statusLabel,
            buttons,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            buttons.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @MainActor
    private func loadSharedPayload() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError(ShareItemProviderDecoderError.missingText.localizedDescription)
            return
        }
        do {
            let payload = try await ShareItemProviderDecoder().decode(items)
            textView.text = payload.text
            sourceURL = payload.sourceURL
            sourceTitle = payload.sourceTitle
            if let sourceURL = payload.sourceURL {
                let title = payload.sourceTitle.map { "\($0)\n" } ?? ""
                sourceLabel.text = "来源：\(title)\(sourceURL.absoluteString)"
                sourceLabel.isHidden = false
            }
            statusLabel.text = "文本可编辑；保存后请正常打开主应用检查。"
            statusLabel.textColor = .secondaryLabel
            saveButton.isEnabled = true
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func saveCapture() {
        do {
            try ShareCaptureActions.apply(
                .save(PendingCapture(
                    text: textView.text ?? "",
                    sourceURL: sourceURL,
                    sourceTitle: sourceTitle
                )),
                inbox: { try PendingCaptureInbox.appGroup() }
            )
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func cancelCapture() {
        _ = try? ShareCaptureActions.apply(
            .cancel,
            inbox: { try PendingCaptureInbox.appGroup() }
        )
        extensionContext?.cancelRequest(
            withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
    }

    private func showError(_ message: String) {
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        saveButton.isEnabled = false
    }
}
