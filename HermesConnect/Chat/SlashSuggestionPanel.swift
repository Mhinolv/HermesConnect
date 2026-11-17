import HermesKit
import InputBarAccessoryView
import Observation
import UIKit

/// Issue #68: the one suggestion model of the app. `HermesConnectApp` sets the live model at launch. Previews and
/// tests get local commands only.
@MainActor
enum SlashSuggestions {
    static var shared: SlashSuggestionModel = {
        #if DEBUG
        if let demo = SlashSuggestionDemo.makeModel() { return demo }
        #endif
        return SlashSuggestionModel(transport: nil, cache: InMemorySlashCatalogCacheStore(), serverKey: { nil })
    }()

    /// The Release model: the chat link, and the catalog cache in Application Support, keyed by the server.
    static func makeLive(link: LiveChatTransport, profile: @escaping @MainActor () -> ServerProfile?)
        -> SlashSuggestionModel {
        let cache: any SlashCatalogCacheStore = (try? FileSlashCatalogCacheStore.applicationSupport())
            ?? InMemorySlashCatalogCacheStore()
        let model = SlashSuggestionModel(transport: link, cache: cache,
                                         serverKey: { profile().map(SlashCatalogServerKey.make) })
        model.start()
        return model
    }
}

/// Issue #68: the suggestion panel in the composer `topStackView`. It moves with the composer, so the #65 gestures
/// stay the same. It reads the field text itself, so the composer code only installs it.
@MainActor
final class SlashSuggestionComposer: NSObject {
    let model: SlashSuggestionModel
    let panel = SlashSuggestionPanelView()
    private weak var field: UITextView?
    private var shownState: SlashPanelState = .hidden
    private let haptic = UISelectionFeedbackGenerator()

    init(model: SlashSuggestionModel = SlashSuggestions.shared) {
        self.model = model
        super.init()
    }

    /// The panel goes above the attachment strip.
    func install(in bar: InputBarAccessoryView) {
        let field = bar.inputTextView
        self.field = field
        bar.topStackView.insertArrangedSubview(panel, at: 0)
        panel.onSelect = { [weak self] suggestion in self?.select(suggestion) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged), name: UITextView.textDidChangeNotification,
                           object: field)
        center.addObserver(self, selector: #selector(textChanged), name: UITextView.textDidBeginEditingNotification,
                           object: field)
        // The keyboard hides (#65 tap or drag, a memo records): the panel hides.
        center.addObserver(self, selector: #selector(endedEditing), name: UITextView.textDidEndEditingNotification,
                           object: field)
        observe()
        #if DEBUG
        SlashSuggestionDemo.start(on: field)
        #endif
    }

    @objc private func textChanged() {
        guard let field else { return }
        guard field.isFirstResponder else {
            model.hide()
            return
        }
        model.update(text: field.text ?? "")
    }

    @objc private func endedEditing() {
        model.hide()
    }

    /// The text from `replace_from` becomes the row text and one space. The keyboard stays. Nothing is sent.
    private func select(_ suggestion: SlashSuggestion) {
        guard let field else { return }
        haptic.selectionChanged()
        // The text change notification updates the composer, the draft and the panel.
        field.text = model.accept(suggestion, in: field.text ?? "")
        field.selectedRange = NSRange(location: (field.text as NSString).length, length: 0)
    }

    private func observe() {
        withObservationTracking {
            _ = model.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.render()
                self?.observe()
            }
        }
        render()
    }

    private func render() {
        let state = model.state
        guard state != shownState else { return }
        let opened = !shownState.isShown && state.isShown
        shownState = state
        panel.show(state, freeHeight: freeHeight())
        guard opened else { return }
        // VoiceOver reads the count once when the panel opens. Focus stays in the field.
        switch state {
        case .rows(let rows, _):
            UIAccessibility.post(notification: .announcement, argument: rows.count == 1 ? "1 command"
                : "\(rows.count) commands")
        case .noMatch:
            UIAccessibility.post(notification: .announcement, argument: SlashPanelState.noMatchText)
        case .loading:
            UIAccessibility.post(notification: .announcement, argument: SlashPanelState.loadingText)
        case .hidden:
            break
        }
    }

    /// The space over the field, under the top safe area.
    private func freeHeight() -> CGFloat {
        guard let field, let window = field.window else { return 600 }
        let top = field.convert(field.bounds, to: window).minY
        return max(0, top - window.safeAreaInsets.top)
    }
}

/// Issue #68: the panel layout values.
enum SlashPanelLayout {
    static let sideInset: CGFloat = 8
    static let topInset: CGFloat = 8
    static let cornerRadius: CGFloat = 16
    static let minRowHeight: CGFloat = 44
    /// The part of the space over the field that the panel can take.
    static let maxShareOfFreeSpace: CGFloat = 0.4

    /// 4.5 rows show (2.5 at accessibility text sizes), so a cut row tells the owner to scroll.
    static func visibleRows(_ category: UIContentSizeCategory) -> CGFloat {
        category.isAccessibilityCategory ? 2.5 : 4.5
    }

    /// The height of the panel for `contentHeight` of rows.
    static func height(contentHeight: CGFloat, rowHeight: CGFloat, category: UIContentSizeCategory,
                       freeHeight: CGFloat) -> CGFloat {
        let byRows = rowHeight * visibleRows(category)
        let byScreen = max(minRowHeight, freeHeight * maxShareOfFreeSpace)
        return ceil(min(contentHeight, byRows, byScreen))
    }
}

/// Issue #68: the glass list of suggestions.
final class SlashSuggestionPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onSelect: ((SlashSuggestion) -> Void)?
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    let table = UITableView(frame: .zero, style: .plain)
    private var state: SlashPanelState = .hidden
    private var heightConstraint: NSLayoutConstraint?
    private var freeHeight: CGFloat = 600

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = SlashPanelLayout.cornerRadius
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        addSubview(glass)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 56
        table.dataSource = self
        table.delegate = self
        table.register(SlashSuggestionCell.self, forCellReuseIdentifier: SlashSuggestionCell.reuseId)
        table.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        table.keyboardDismissMode = .none
        table.accessibilityLabel = "Command suggestions"
        glass.contentView.addSubview(table)
        let height = glass.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor, constant: SlashPanelLayout.topInset),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SlashPanelLayout.sideInset),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SlashPanelLayout.sideInset),
            table.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            table.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            height,
        ])
        isHidden = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.table.reloadData()
            self.updateHeight()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var shownState: SlashPanelState { state }

    func show(_ newState: SlashPanelState, freeHeight: CGFloat) {
        let rowsChanged = newState.rows.map(\.id) != state.rows.map(\.id) || !newState.isShown
        state = newState
        self.freeHeight = freeHeight
        isHidden = !newState.isShown
        guard newState.isShown else { return }
        table.reloadData()
        if rowsChanged { table.setContentOffset(CGPoint(x: 0, y: -table.contentInset.top), animated: false) }
        updateHeight()
    }

    private func updateHeight() {
        guard state.isShown else { return }
        table.layoutIfNeeded()
        let content = table.contentSize.height + table.contentInset.top + table.contentInset.bottom
        let category = traitCollection.preferredContentSizeCategory
        heightConstraint?.constant = SlashPanelLayout.height(
            contentHeight: content, rowHeight: SlashSuggestionCell.rowHeight(traits: traitCollection),
            category: category, freeHeight: freeHeight)
        table.isScrollEnabled = content > (heightConstraint?.constant ?? 0) + 0.5
    }

    // MARK: Table

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        switch state {
        case .hidden: 0
        case .loading, .noMatch: 1
        case .rows(let rows, _): rows.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SlashSuggestionCell.reuseId, for: indexPath)
        guard let cell = cell as? SlashSuggestionCell else { return cell }
        switch state {
        case .rows(let rows, _): cell.show(rows[indexPath.row])
        case .loading: cell.showStatus(SlashPanelState.loadingText, spinner: true)
        case .noMatch: cell.showStatus(SlashPanelState.noMatchText, spinner: false)
        case .hidden: break
        }
        return cell
    }

    func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < state.rows.count
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let rows = state.rows
        guard indexPath.row < rows.count else { return }
        onSelect?(rows[indexPath.row])
    }
}

/// Issue #68: one row. `/name` in `.body` semibold, then the description in `.subheadline` secondary. One line
/// each. At accessibility text sizes, the description has 2 lines.
final class SlashSuggestionCell: UITableViewCell {
    static let reuseId = "SlashSuggestionCell"
    static let hint = "Puts the command in the message field."
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stack = UIStackView()

    static var titleFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
    }

    /// The height of a row with a title and one description line, for the panel height.
    static func rowHeight(traits: UITraitCollection) -> CGFloat {
        let title = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
        let detail = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight
        let lines: CGFloat = traits.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
        return max(SlashPanelLayout.minRowHeight, ceil(title + detail * lines + 2 + 16))
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = .systemFill
        selectedBackgroundView = selected
        titleLabel.font = Self.titleFont
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.lineBreakMode = .byTruncatingTail
        spinner.hidesWhenStopped = true
        let titleRow = UIStackView(arrangedSubviews: [spinner, titleLabel])
        titleRow.spacing = 8
        titleRow.alignment = .center
        stack.axis = .vertical
        stack.spacing = 2
        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let minHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: SlashPanelLayout.minRowHeight)
        minHeight.priority = .required - 1
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            minHeight,
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ suggestion: SlashSuggestion) {
        spinner.stopAnimating()
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .label
        titleLabel.text = suggestion.title
        detailLabel.text = suggestion.detail
        detailLabel.isHidden = suggestion.detail.isEmpty
        detailLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
        titleLabel.numberOfLines = 1
        selectionStyle = .default
        accessibilityLabel = suggestion.accessibilityLabel
        accessibilityHint = Self.hint
        accessibilityTraits = .button
    }

    /// "Loading commands…" with a spinner, or "No matching commands". Not tappable.
    func showStatus(_ text: String, spinner showsSpinner: Bool) {
        if showsSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = text
        titleLabel.numberOfLines = 0
        detailLabel.text = nil
        detailLabel.isHidden = true
        selectionStyle = .none
        accessibilityLabel = text
        accessibilityHint = nil
        accessibilityTraits = .staticText
    }
}

#if DEBUG
/// Issue #68: DEBUG screenshots of the panel. `HERMES_DEMO=keyboard HERMES_DEMO_SLASH=<list|filtered|no-match|loading>`.
@MainActor
enum SlashSuggestionDemo {
    enum Scenario: String {
        /// A bare `/`: the whole catalog, so the panel scrolls.
        case list
        /// `/s`: the server rows for `s`.
        case filtered
        case noMatch = "no-match"
        /// Connected, no catalog yet, and no local match.
        case loading
    }

    static var current: Scenario? {
        ProcessInfo.processInfo.environment["HERMES_DEMO_SLASH"].flatMap(Scenario.init(rawValue:))
    }

    nonisolated static let catalog = CommandsCatalogResult(pairs: [
        ["/model", "Switch the model"], ["/help", "Show the commands"], ["/skills", "Search and install skills"],
        ["/summarize", "Summarize this chat"], ["/compress", "Compress the context of this chat"],
        ["/personality", "Set the personality"], ["/status", "Show the session status"],
    ], canon: ["/m": "/model"])

    /// The app sets the demo model before the first chat screen.
    static func makeModel() -> SlashSuggestionModel? {
        guard let scenario = current else { return nil }
        let transport = DemoSlashTransport(scenario: scenario)
        let model = SlashSuggestionModel(transport: transport, cache: InMemorySlashCatalogCacheStore(),
                                         serverKey: { "demo" })
        model.start()
        transport.connect()
        return model
    }

    static func start(on field: UITextView) {
        guard let scenario = current else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            _ = field.becomeFirstResponder()
            field.text = switch scenario {
            case .list: "/"
            case .filtered: "/s"
            case .noMatch: "/zzz"
            case .loading: "/sk"
            }
        }
    }
}

/// A connected server with the demo catalog. `loading` never answers.
private final class DemoSlashTransport: SlashCompletionTransport, @unchecked Sendable {
    let scenario: SlashSuggestionDemo.Scenario
    let events: AsyncStream<GatewayClientEvent>
    private let continuation: AsyncStream<GatewayClientEvent>.Continuation

    init(scenario: SlashSuggestionDemo.Scenario) {
        self.scenario = scenario
        (events, continuation) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    func connect() {
        continuation.yield(.state(.connected(GatewayReady(replayEpoch: "demo"))))
    }

    func commandsCatalog() async throws -> CommandsCatalogResult {
        if scenario == .loading { try await Task.sleep(for: .seconds(3600)) }
        return SlashSuggestionDemo.catalog
    }

    func completeSlash(text: String) async throws -> SlashCompletionResult {
        if scenario == .loading { try await Task.sleep(for: .seconds(3600)) }
        guard text == "/s" else { throw GatewayError.notConnected }
        return SlashCompletionResult(items: [
            SlashCompletionItem(text: "/skills", display: "/skills", meta: "Search and install skills"),
            SlashCompletionItem(text: "/summarize", display: "/summarize", meta: "Summarize this chat"),
            SlashCompletionItem(text: "/status", display: "/status", meta: "Show the session status"),
            SlashCompletionItem(text: "/usage", display: "/usage", meta: "Show the token usage of this chat"),
        ], replaceFrom: 1)
    }
}
#endif
