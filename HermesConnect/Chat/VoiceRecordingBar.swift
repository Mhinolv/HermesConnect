import HermesKit
import UIKit

/// Draws level bars from 0 to 1. The bubble shows the whole memo. The recording bar shows the newest levels.
final class VoiceWaveformView: UIView {
    var levels: [Float] = [] { didSet { setNeedsDisplay() } }
    var barColor: UIColor = .label { didSet { setNeedsDisplay() } }
    /// Bars drawn. The recording bar keeps the newest, so the wave moves from right to left.
    var barCount = VoiceMemoLimits.waveformBars
    var alignsNewestRight = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard barCount > 0, bounds.width > 0 else { return }
        let slot = bounds.width / CGFloat(barCount)
        let width = max(2, slot * 0.55)
        let shown: [Float] = alignsNewestRight
            ? Array(repeating: 0, count: max(0, barCount - levels.count)) + levels.suffix(barCount)
            : levels
        barColor.setFill()
        for (index, level) in shown.prefix(barCount).enumerated() {
            let height = max(3, CGFloat(level) * bounds.height)
            let x = CGFloat(index) * slot + (slot - width) / 2
            let bar = CGRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            UIBezierPath(roundedRect: bar, cornerRadius: width / 2).fill()
        }
    }
}

/// The composer while a memo records (issue #9 design notes).
///
/// | Mode | Left | Middle | Right |
/// |---|---|---|---|
/// | Hold | "Slide to Cancel" | red dot, timer, waveform | red mic under the finger |
/// | Tap | Cancel (`xmark`, 56 pt) | red dot, timer, waveform | Send (64 pt) |
/// | Paused | Cancel | pause symbol, timer, "Paused" | Send |
final class VoiceRecordingBar: UIView {
    enum Mode: Equatable {
        case hold(cancelProgress: Double)
        case tap
        case paused
    }

    let cancelButton = UIButton(type: .system)
    let sendButton = UIButton(type: .system)
    private let dot = UIView()
    private let pauseIcon = UIImageView(image: UIImage(systemName: "pause.fill"))
    private let timeLabel = UILabel()
    private let waveform = VoiceWaveformView()
    private let pausedLabel = UILabel()
    private let slideHint = UILabel()
    private let holdMic = UIImageView(image: UIImage(systemName: "mic.circle.fill"))
    private var slideHintCenter: NSLayoutConstraint?
    private(set) var mode: Mode = .tap
    private var lastAnnouncedTime = ""

    var onCancel: (() -> Void)?
    var onSend: (() -> Void)?

    static let height: CGFloat = 64

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    private func setUp() {
        var cancel = UIButton.Configuration.plain()
        cancel.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22,
                                                                                                    weight: .semibold))
        cancel.baseForegroundColor = .secondaryLabel
        cancelButton.configuration = cancel
        cancelButton.accessibilityLabel = "Cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)

        var send = UIButton.Configuration.plain()
        send.image = UIImage(systemName: "arrow.up.circle.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 44))
        send.baseForegroundColor = .systemBlue
        send.contentInsets = .zero
        sendButton.configuration = send
        sendButton.accessibilityLabel = "Send"
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)

        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 5
        pauseIcon.tintColor = .secondaryLabel
        pauseIcon.contentMode = .scaleAspectFit
        pauseIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)

        timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                                                          weight: .regular)
        timeLabel.adjustsFontForContentSizeCategory = false
        timeLabel.textColor = .label
        timeLabel.text = "0:00"
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        waveform.barColor = .secondaryLabel
        waveform.barCount = 28
        waveform.alignsNewestRight = true

        pausedLabel.text = "Paused"
        pausedLabel.font = .preferredFont(forTextStyle: .subheadline)
        pausedLabel.textColor = .secondaryLabel

        slideHint.text = "‹ Slide to Cancel"
        slideHint.font = .preferredFont(forTextStyle: .subheadline)
        slideHint.textColor = .secondaryLabel
        slideHint.adjustsFontSizeToFitWidth = true
        slideHint.minimumScaleFactor = 0.7
        slideHint.isAccessibilityElement = false

        holdMic.tintColor = .systemRed
        holdMic.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 52)
        holdMic.contentMode = .center
        holdMic.isAccessibilityElement = false

        let views: [UIView] = [cancelButton, dot, pauseIcon, timeLabel, waveform, pausedLabel, slideHint, holdMic,
                               sendButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let hintCenter = slideHint.centerXAnchor.constraint(equalTo: waveform.centerXAnchor)
        slideHintCenter = hintCenter
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 56),
            cancelButton.heightAnchor.constraint(equalToConstant: 56),

            dot.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            pauseIcon.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            pauseIcon.centerYAnchor.constraint(equalTo: centerYAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            waveform.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 10),
            waveform.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            waveform.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 28),
            pausedLabel.leadingAnchor.constraint(equalTo: waveform.leadingAnchor),
            pausedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            hintCenter,
            slideHint.centerYAnchor.constraint(equalTo: centerYAnchor),
            slideHint.widthAnchor.constraint(lessThanOrEqualTo: waveform.widthAnchor),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 64),
            sendButton.heightAnchor.constraint(equalToConstant: 64),
            holdMic.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            holdMic.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
        ])
        timeLabel.accessibilityTraits = .updatesFrequently
        apply(mode: .tap)
    }

    /// Updates the bar. Called on each timer step, so it does little work.
    func update(mode: Mode, elapsed: TimeInterval, levels: [Float]) {
        if mode != self.mode { apply(mode: mode) }
        let text = VoiceMemoFormat.duration(elapsed)
        if timeLabel.text != text {
            timeLabel.text = text
            timeLabel.accessibilityLabel = "Recording, \(VoiceMemoFormat.spokenDuration(elapsed))"
        }
        if case .paused = mode {} else { waveform.levels = Array(levels.suffix(waveform.barCount)) }
        if case .hold(let progress) = mode {
            slideHintCenter?.constant = -CGFloat(progress) * 60
            slideHint.alpha = 1 - CGFloat(progress) * 0.7
        }
    }

    private func apply(mode: Mode) {
        self.mode = mode
        let holding: Bool
        if case .hold = mode { holding = true } else { holding = false }
        let paused = mode == .paused
        cancelButton.isHidden = holding
        sendButton.isHidden = holding
        holdMic.isHidden = !holding
        slideHint.isHidden = !holding
        waveform.isHidden = holding || paused
        pausedLabel.isHidden = !paused
        dot.isHidden = paused
        pauseIcon.isHidden = !paused
        timeLabel.textColor = paused ? .secondaryLabel : .label
        if !holding {
            slideHintCenter?.constant = 0
            slideHint.alpha = 1
        }
        updatePulse()
    }

    /// The red dot pulses while it records, unless Reduce Motion is on.
    private func updatePulse() {
        dot.layer.removeAnimation(forKey: "pulse")
        guard !dot.isHidden, !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer.add(pulse, forKey: "pulse")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePulse()
    }
}
