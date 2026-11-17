import AVFoundation
import HermesKit
import InputBarAccessoryView
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The `plus` menu of the composer and the pending items (issue #8).
///
/// - Menu: "Photos" (up to 10), "Camera" (hidden with no camera), "Files", "Send Location".
/// - Picked items wait in the strip above the text view until Send. A pasted image joins them.
/// - "Send Location" reads one fix and sends a map card at once (research.md D4).
/// - Size caps show an alert before any upload (docs/hermes-protocol.md 3.8).
@MainActor
final class AttachmentComposer: NSObject {
    private(set) var pending: [ChatAttachment] = []
    /// The pending list changed. The chat screen updates the Send button.
    var onChange: (() -> Void)?
    /// "Send Location": the text line and the map card, sent at once.
    var sendNow: ((String, [ChatAttachment]) -> Void)?
    private weak var presenter: UIViewController?
    private weak var bar: InputBarAccessoryView?
    let strip = AttachmentStripView()
    let plusButton = InputBarButtonItem()
    private let location = OneTimeLocation()

    var hasPending: Bool { !pending.isEmpty }

    /// The one input bar hook: the `plus` button on the left, the strip on top, image paste.
    func install(in bar: InputBarAccessoryView, presenter: UIViewController) {
        AttachmentImport.clearEarlierLaunches()
        self.bar = bar
        self.presenter = presenter
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17,
                                                                                                  weight: .semibold))
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        plusButton.configuration = config
        // Issue #49: 44 pt, the height of the one-line field and the mic, so all three share one center line.
        plusButton.setSize(CGSize(width: ChatComposerLayout.control, height: ChatComposerLayout.control),
                           animated: false)
        plusButton.accessibilityLabel = "Attach"
        plusButton.showsMenuAsPrimaryAction = true
        plusButton.menu = makeMenu()
        setPlusShown(true)
        strip.onRemove = { [weak self] id in self?.remove(id: id) }
        bar.topStackView.addArrangedSubview(strip)
        bar.inputPlugins.append(self)
        AttachmentThumbnails.onReady[ObjectIdentifier(self)] = { [weak self] in
            guard let self else { return }
            self.strip.show(self.pending)
        }
        #if DEBUG
        if AttachmentDemo.isActive { add(AttachmentDemo.pendingItems()) }
        #endif
    }

    /// Issue #49: the `plus` button hides while a memo records, and the recording bar takes its space.
    func setPlusShown(_ shown: Bool) {
        guard let bar else { return }
        plusButton.isHidden = !shown
        bar.setStackViewItems(shown ? [plusButton] : [], forStack: .left, animated: false)
        bar.setLeftStackViewWidthConstant(to: shown ? ChatComposerLayout.control : 0, animated: false)
        bar.middleContentViewPadding.left = shown ? 8 : 0
    }

    /// Send: the pending items go with the message, and the strip clears.
    func takeAll() -> [ChatAttachment] {
        let items = pending
        pending = []
        changed()
        return items
    }

    func add(_ items: [ChatAttachment]) {
        guard !items.isEmpty else { return }
        pending += items
        changed()
    }

    func remove(id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        AttachmentImport.discard(pending.remove(at: index))
        changed()
    }

    private func changed() {
        strip.show(pending)
        bar?.invalidateIntrinsicContentSize()
        onChange?()
    }

    // MARK: Menu

    static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    private func makeMenu() -> UIMenu {
        var items: [UIMenuElement] = [
            UIAction(title: "Photos", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                self?.showPhotos()
            },
        ]
        if Self.hasCamera {
            items.append(UIAction(title: "Camera", image: UIImage(systemName: "camera")) { [weak self] _ in
                self?.showCamera()
            })
        }
        items.append(UIAction(title: "Files", image: UIImage(systemName: "doc")) { [weak self] _ in
            self?.showFiles()
        })
        items.append(UIAction(title: "Send Location", image: UIImage(systemName: "location")) { [weak self] _ in
            self?.sendLocation()
        })
        return UIMenu(children: items)
    }

    private func showPhotos() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = AttachmentLimits.maxPhotos
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    private func showCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            showSettingsAlert(title: "Camera Access Off",
                              message: "Turn on camera access for Hermes in Settings to take photos.")
            return
        default:
            break
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    private func showFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    private func sendLocation() {
        location.request { [weak self] result in
            guard let self else { return }
            switch result {
            case .denied:
                self.showSettingsAlert(title: "Location Access Off",
                                       message: "Turn on location access for Hermes in Settings to send your location.")
            case .failed:
                self.showAlert(title: "Location Not Available", message: "Hermes could not read your location. Try again.")
            case .fix(let fix):
                Task { @MainActor in
                    let card = await LocationCardSnapshot.make(fix, traits: self.presenter?.traitCollection)
                    let items = card.flatMap { try? AttachmentImport.locationCard($0) }.map { [$0] } ?? []
                    self.sendNow?(LocationShareText.make(fix), items)
                }
            }
        }
    }

    // MARK: Alerts

    private func showAlert(title: String, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }

    private func showSettingsAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        presentAlert(alert)
    }

    private func showTooLarge() {
        showAlert(title: AttachmentLimits.tooLargeTitle, message: AttachmentLimits.tooLargeMessage)
    }

    private func presentAlert(_ alert: UIAlertController) {
        var top = presenter
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        top?.present(alert, animated: true)
    }

    /// PDFs over 25 pages ask first: "Hermes reads the first 25 pages." with "Send" and "Cancel".
    private func addChecked(_ items: [ChatAttachment]) {
        var ready: [ChatAttachment] = []
        var long: [ChatAttachment] = []
        for item in items {
            if case .pdfPagesOver = AttachmentLimits.check(kind: item.kind, byteCount: item.byteCount,
                                                           pageCount: item.pageCount) {
                long.append(item)
            } else {
                ready.append(item)
            }
        }
        add(ready)
        for item in long {
            let alert = UIAlertController(title: AttachmentLimits.pdfPagesTitle, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in AttachmentImport.discard(item) })
            alert.addAction(UIAlertAction(title: "Send", style: .default) { [weak self] _ in self?.add([item]) })
            presentAlert(alert)
        }
    }

    /// Photo data goes through the encoder off the main thread. The order of the picks stays.
    private func importPhotos(_ sources: [Data]) {
        Task {
            var items: [ChatAttachment] = []
            var tooLarge = false
            for data in sources {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<ChatAttachment, any Error> in
                    Result { try AttachmentImport.photo(from: data) }
                }.value
                switch result {
                case .success(let item): items.append(item)
                case .failure(AttachmentImport.Failure.tooLarge): tooLarge = true
                case .failure: break
                }
            }
            add(items)
            if tooLarge { showTooLarge() }
        }
    }
}

// MARK: - Paste

extension AttachmentComposer: InputPlugin {
    func reloadData() {}

    func invalidate() {
        pending.forEach(AttachmentImport.discard)
        pending = []
        changed()
    }

    /// A pasted image joins the pending items, not the text.
    func handleInput(of object: AnyObject) -> Bool {
        guard let image = object as? UIImage, let data = image.pngData() else { return false }
        importPhotos([data])
        return true
    }
}

// MARK: - Pickers

extension AttachmentComposer: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        Task {
            var sources: [Data] = []
            for result in results {
                if let data = await Self.imageData(result.itemProvider) { sources.append(data) }
            }
            importPhotos(sources)
        }
    }

    private static func imageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                continuation.resume(returning: nil)
                return
            }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

extension AttachmentComposer: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) else {
            return
        }
        importPhotos([data])
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension AttachmentComposer: UIDocumentPickerDelegate {
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var items: [ChatAttachment] = []
        var tooLarge = false
        for url in urls {
            do {
                items.append(try AttachmentImport.file(at: url))
            } catch AttachmentImport.Failure.tooLarge {
                tooLarge = true
            } catch {
                continue
            }
        }
        addChecked(items)
        if tooLarge { showTooLarge() }
    }
}
