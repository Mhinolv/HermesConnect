import HermesKit
import UIKit

/// Draws level bars from 0 to 1. The bubble shows the whole memo. The recording bar shows the newest levels.
final class VoiceWaveformView: UIView {
    var levels: [Float] = [] { didSet { setNeedsDisplay() } }
    var barColor: UIColor = .label { didSet { setNeedsDisplay() } }
    /// Bars drawn. The recording bar keeps the newest, so the wave moves from right to left.
    var barCount = VoiceMemoLimits.waveformBars
    var alignsNewestRight = false
    /// Issue #49: the played part of a voice reply, from 0 to 1. Bars before it use `playedColor`.
    /// `nil` draws every bar in `barColor` (memos and the recording bar).
    var progress: CGFloat? { didSet { if progress != oldValue { setNeedsDisplay() } } }
    var playedColor: UIColor = .label { didSet { setNeedsDisplay() } }

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
        for (index, level) in shown.prefix(barCount).enumerated() {
            let height = max(3, CGFloat(level) * bounds.height)
            let x = CGFloat(index) * slot + (slot - width) / 2
            let bar = CGRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            let played = progress.map { (CGFloat(index) + 0.5) / CGFloat(barCount) <= $0 } ?? false
            (played ? playedColor : barColor).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: width / 2).fill()
        }
    }
}

/// The Glass Capsule: the composer while a memo records (issue #103 design notes, frames 01–10).
///
/// | Mode | Top line | Capsule | Keys |
/// |---|---|---|---|
/// | Hold | "Slide to cancel", lock pill | red glass, dot, timer, bars | the red mic under the finger |
/// | Cancel armed | "Slide back to keep recording" | full red, trash, "Release to delete" | the red mic |
/// | Locked | "Locked" | red glass, dot, timer, bars | Delete, Pause, Send (56 pt) |
/// | Paused | "Paused · play, add more, or send" | Play, `0:07 / 0:22`, static bars | Delete, Add More, Send |
///
/// Near the limit (9:30) the timer is orange and counts down. Reduce Motion: the bars update in place,
/// the mic halo is static, and the dot does not pulse.
final class VoiceRecordingBar: UIView {
    enum Mode: Equatable {
        case hold(cancelProgress: Double, lockProgress: Double)
        case cancelArmed
        case locked
        case paused
    }

    let deleteButton = UIButton(type: .system)
    /// Pause while it records, Add More while paused.
    let middleButton = UIButton(type: .system)
    let sendButton = UIButton(type: .system)
    let playButton = UIButton(type: .system)
    let timeLabel = UILabel()
    let statusLabel = UILabel()
    private let capsule = UIVisualEffectView()
    private let dot = UIView()
    private let waveform = VoiceWaveformView()
    private let trashIcon = UIImageView(image: UIImage(systemName: "trash"))
    private let releaseLabel = UILabel()
    private let lockPill = UIVisualEffectView(effect: UIGlassEffect())
    private let lockIcon = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up"))
    private let holdMic = UIView()
    private let holdHalo = UIView()
    private let holdMicIcon = UIImageView(image: UIImage(systemName: "mic.fill"))
    private(set) var mode: Mode = .locked
    private var elapsed: TimeInterval = 0
    private var levels: [Float] = []
    /// The play position of the paused clip, and `true` while it plays.
    private var playback: (time: TimeInterval, playing: Bool) = (0, false)
    private var tinted: Bool?

    var onDelete: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onSend: (() -> Void)?
    var onPlay: (() -> Void)?
    /// Tests turn Reduce Motion on.
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    static let keySize: CGFloat = 56
    /// The Play symbol fits its 44 pt key at every text size.
    private static let playSymbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    static let micSize: CGFloat = 64
    /// The room above the capsule for the lock pill while the owner holds the mic.
    static let holdTop: CGFloat = 84

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Metrics

    private var timerFont: UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, maximumPointSize: 28,
                                                             compatibleWith: traitCollection)
    }

    private var statusFont: UIFont { .preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection) }

    var capsuleHeight: CGFloat { max(44, (timerFont.lineHeight + 18).rounded(.up)) }

    private var statusHeight: CGFloat { (statusFont.lineHeight + 6).rounded(.up) }

    /// The bar height of a mode. The input bar reads it to size the composer.
    func height(for mode: Mode) -> CGFloat {
        switch mode {
        case .hold, .cancelArmed:
            Self.holdTop + max(Self.micSize, capsuleHeight)
        case .locked, .paused:
            statusHeight + 6 + capsuleHeight + 10 + Self.keySize
        }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height(for: mode)) }

    // MARK: Set up

    private func setUp() {
        clipsToBounds = false
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.6

        capsule.clipsToBounds = true
        capsule.layer.cornerCurve = .continuous
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 5
        dot.isAccessibilityElement = false
        timeLabel.textColor = .label
        timeLabel.accessibilityTraits = .updatesFrequently
        waveform.barColor = .label
        trashIcon.tintColor = .white
        trashIcon.contentMode = .scaleAspectFit
        releaseLabel.text = "Release to delete"
        releaseLabel.textColor = .white
        releaseLabel.adjustsFontSizeToFitWidth = true
        releaseLabel.minimumScaleFactor = 0.5
        releaseLabel.isAccessibilityElement = false
        for view in [dot, timeLabel, waveform, trashIcon, releaseLabel, playButton] as [UIView] {
            capsule.contentView.addSubview(view)
        }

        lockPill.clipsToBounds = true
        lockPill.layer.cornerRadius = 20
        lockPill.isAccessibilityElement = false
        for icon in [lockIcon, chevron] {
            icon.tintColor = .secondaryLabel
            icon.contentMode = .center
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            lockPill.contentView.addSubview(icon)
        }

        holdHalo.backgroundColor = UIColor.systemRed.withAlphaComponent(0.25)
        holdHalo.isUserInteractionEnabled = false
        holdMic.backgroundColor = .systemRed
        holdMic.isUserInteractionEnabled = false
        holdMicIcon.tintColor = .white
        holdMicIcon.contentMode = .center
        holdMicIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        holdMic.addSubview(holdMicIcon)
        holdMic.isAccessibilityElement = false

        configureKey(deleteButton, symbol: "trash", color: .systemRed, label: "Delete Recording") { [weak self] in
            self?.onDelete?()
        }
        configureKey(middleButton, symbol: "pause.fill", color: .label, label: "Pause Recording") { [weak self] in
            guard let self else { return }
            if self.mode == .paused { self.onResume?() } else { self.onPause?() }
        }
        var send = UIButton.Configuration.plain()
        send.image = UIImage(systemName: "arrow.up.circle.fill", withConfiguration: UIImage.SymbolConfiguration(
            pointSize: 44).applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])))
        send.baseForegroundColor = .systemBlue
        send.contentInsets = .zero
        sendButton.configuration = send
        sendButton.accessibilityLabel = "Send Voice Memo"
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)

        var play = UIButton.Configuration.plain()
        play.baseForegroundColor = .label
        play.contentInsets = .zero
        playButton.configuration = play
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)

        for view in [statusLabel, capsule, lockPill, holdHalo, holdMic, deleteButton, middleButton, sendButton]
            as [UIView] {
            addSubview(view)
        }
        accessibilityElements = [statusLabel, playButton, timeLabel, deleteButton, middleButton, sendButton]
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: VoiceRecordingBar, _) in
            bar.applyFonts()
            bar.invalidateIntrinsicContentSize()
            bar.setNeedsLayout()
        }
        applyFonts()
        apply(mode: .locked)
    }

    private func configureKey(_ button: UIButton, symbol: String, color: UIColor, label: String,
                              action: @escaping () -> Void) {
        var config = UIButton.Configuration.glass()
        config.image = Self.keyImage(symbol, color: color)
        config.cornerStyle = .capsule
        button.configuration = config
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    /// The glass style draws a template symbol in its own color, so the key symbols keep their color.
    private static func keyImage(_ symbol: String, color: UIColor) -> UIImage? {
        UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }

    private func applyFonts() {
        timeLabel.font = timerFont
        statusLabel.font = statusFont
        releaseLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 28, compatibleWith: traitCollection)
        let symbol = UIImage.SymbolConfiguration(font: timerFont)
        trashIcon.preferredSymbolConfiguration = symbol
        playButton.configuration?.image = UIImage(systemName: playback.playing ? "pause.fill" : "play.fill",
                                                  withConfiguration: Self.playSymbol)
    }

    // MARK: Update

    /// Updates the bar. Called on each timer step, so it does little work.
    func update(mode: Mode, elapsed: TimeInterval, levels: [Float]) {
        self.elapsed = elapsed
        self.levels = levels
        if mode != self.mode {
            let resized = height(for: mode) != height(for: self.mode)
            apply(mode: mode)
            if resized { invalidateIntrinsicContentSize() }
        }
        updateTimer()
        updateWaveform()
        if case .hold = mode { updateHalo() }
        setNeedsLayout()
    }

    /// The play position of the paused clip.
    func setPlayback(time: TimeInterval, playing: Bool) {
        let changed = playing != playback.playing
        playback = (time, playing)
        if changed {
            playButton.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill",
                                                      withConfiguration: Self.playSymbol)
            playButton.accessibilityLabel = playing ? "Pause Playback" : "Play Recording"
        }
        updateTimer()
        updateWaveform()
    }

    private func apply(mode: Mode) {
        let wasPaused = self.mode == .paused
        self.mode = mode
        let holding: Bool
        if case .hold = mode { holding = true } else { holding = false }
        let armed = mode == .cancelArmed
        let paused = mode == .paused
        let keys = !holding && !armed
        deleteButton.isHidden = !keys
        middleButton.isHidden = !keys
        sendButton.isHidden = !keys
        holdMic.isHidden = keys
        holdHalo.isHidden = keys
        lockPill.isHidden = !holding
        playButton.isHidden = !paused
        dot.isHidden = paused || armed
        timeLabel.isHidden = armed
        waveform.isHidden = armed
        trashIcon.isHidden = !armed
        releaseLabel.isHidden = !armed
        setTint(full: armed)
        // VoiceOver uses the locked mode only (design notes). The hold controls are not elements.
        timeLabel.isAccessibilityElement = keys
        statusLabel.isAccessibilityElement = paused

        switch mode {
        case .hold:
            statusLabel.attributedText = nil
            statusLabel.text = "‹ Slide to cancel"
        case .cancelArmed:
            statusLabel.attributedText = nil
            statusLabel.text = "Slide back to keep recording"
        case .locked:
            let text = NSMutableAttributedString(attachment: NSTextAttachment(
                image: UIImage(systemName: "lock.fill")?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
                    ?? UIImage()))
            text.append(NSAttributedString(string: " Locked"))
            statusLabel.attributedText = text
        case .paused:
            statusLabel.attributedText = nil
            statusLabel.text = "Paused · play, add more, or send"
        }
        var middle = middleButton.configuration
        middle?.image = Self.keyImage(paused ? "mic.fill" : "pause.fill", color: paused ? .systemRed : .label)
        middleButton.configuration = middle
        middleButton.accessibilityLabel = paused ? "Resume Recording" : "Pause Recording"
        if paused != wasPaused { playback = (0, false) }
        playButton.accessibilityLabel = playback.playing ? "Pause Playback" : "Play Recording"
        waveform.alignsNewestRight = !paused && !reduceMotion()
        waveform.barColor = paused ? .tertiaryLabel : .label
        waveform.playedColor = .systemBlue
        updatePulse()
        updateHalo()
    }

    private func setTint(full: Bool) {
        guard tinted != full else { return }
        tinted = full
        let glass = UIGlassEffect()
        glass.tintColor = full ? UIColor.systemRed : UIColor.systemRed.withAlphaComponent(0.12)
        capsule.effect = glass
    }

    private func updateTimer() {
        let text: String
        let spoken: String
        var color: UIColor = .label
        switch mode {
        case .paused:
            text = "\(VoiceMemoFormat.duration(playback.time)) / \(VoiceMemoFormat.duration(elapsed))"
            spoken = "Paused, \(VoiceMemoFormat.spokenDuration(playback.time)) of "
                + VoiceMemoFormat.spokenDuration(elapsed)
        default:
            if elapsed >= VoiceMemoLimits.warningAt {
                let left = max(0, VoiceMemoLimits.maxDuration - elapsed)
                text = VoiceMemoFormat.duration(left)
                spoken = "Recording, \(VoiceMemoFormat.spokenDuration(left)) left"
                color = .systemOrange
            } else {
                text = VoiceMemoFormat.duration(elapsed)
                spoken = "Recording, \(VoiceMemoFormat.spokenDuration(elapsed))"
            }
        }
        if timeLabel.text != text {
            timeLabel.text = text
            timeLabel.accessibilityLabel = spoken
            setNeedsLayout()
        }
        if timeLabel.textColor != color { timeLabel.textColor = color }
    }

    private func updateWaveform() {
        let count = max(8, Int(waveform.bounds.width / 5))
        if waveform.barCount != count { waveform.barCount = count }
        switch mode {
        case .paused:
            waveform.levels = VoiceWaveform.bars(from: levels, count: count)
            waveform.progress = elapsed > 0 ? CGFloat(min(1, playback.time / elapsed)) : 0
        case .cancelArmed:
            break
        default:
            waveform.progress = nil
            waveform.levels = reduceMotion() ? Self.inPlace(levels, count: count) : Array(levels.suffix(count))
        }
    }

    /// Reduce Motion: each bar keeps its place. A new level writes over the oldest bar, with no slide.
    static func inPlace(_ levels: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var shown = [Float](repeating: 0, count: count)
        for index in max(0, levels.count - count)..<levels.count {
            shown[index % count] = levels[index]
        }
        return shown
    }

    /// The halo of the hold mic follows the level. Reduce Motion: a static halo.
    private func updateHalo() {
        let level = reduceMotion() ? 0.3 : CGFloat(levels.last ?? 0)
        holdHalo.transform = CGAffineTransform(scaleX: 1 + level * 0.45, y: 1 + level * 0.45)
    }

    /// The red dot pulses while it records, unless Reduce Motion is on.
    private func updatePulse() {
        dot.layer.removeAnimation(forKey: "pulse")
        guard !dot.isHidden, window != nil, !reduceMotion() else { return }
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

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let capH = capsuleHeight
        let statusH = statusHeight
        let holding: Bool
        if case .hold = mode { holding = true } else { holding = mode == .cancelArmed }
        let trailingInset: CGFloat
        if holding {
            let rowH = max(Self.micSize, capH)
            let rowY = Self.holdTop
            let mic = Self.micSize
            let micCenter = CGPoint(x: width - mic / 2, y: rowY + rowH / 2)
            capsule.frame = CGRect(x: 0, y: rowY + (rowH - capH) / 2, width: width - 8, height: capH)
            holdHalo.bounds = CGRect(x: 0, y: 0, width: mic, height: mic)
            holdHalo.center = micCenter
            holdHalo.layer.cornerRadius = mic / 2
            holdMic.bounds = CGRect(x: 0, y: 0, width: mic, height: mic)
            holdMic.center = micCenter
            holdMic.layer.cornerRadius = mic / 2
            holdMic.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
            holdMicIcon.frame = holdMic.bounds
            var lock: Double = 0
            var cancel: Double = 0
            if case .hold(let c, let l) = mode { lock = l; cancel = c }
            let pillH: CGFloat = 72
            lockPill.frame = CGRect(x: micCenter.x - 20, y: rowY - pillH - 6 - CGFloat(lock) * 14, width: 40,
                                    height: pillH)
            lockIcon.frame = CGRect(x: 0, y: 8, width: 40, height: 24)
            chevron.frame = CGRect(x: 0, y: 38, width: 40, height: 24)
            lockPill.alpha = 1 - CGFloat(cancel) * 0.8
            let hintW = max(0, width - 2 * (mic + 8))
            statusLabel.frame = CGRect(x: (width - hintW) / 2 - CGFloat(cancel) * 40, y: rowY - statusH - 4,
                                       width: hintW, height: statusH)
            statusLabel.alpha = mode == .cancelArmed ? 1 : 1 - CGFloat(cancel) * 0.6
            trailingInset = mic + 4
        } else {
            statusLabel.alpha = 1
            statusLabel.frame = CGRect(x: 0, y: 0, width: width, height: statusH)
            capsule.frame = CGRect(x: 0, y: statusH + 6, width: width, height: capH)
            let keyY = capsule.frame.maxY + 10
            let key = Self.keySize
            deleteButton.frame = CGRect(x: 0, y: keyY, width: key, height: key)
            middleButton.frame = CGRect(x: (width - key) / 2, y: keyY, width: key, height: key)
            sendButton.frame = CGRect(x: width - key, y: keyY, width: key, height: key)
            trailingInset = 0
        }
        capsule.layer.cornerRadius = capH / 2
        layoutCapsule(height: capH, trailingInset: trailingInset)
    }

    private func layoutCapsule(height: CGFloat, trailingInset: CGFloat) {
        let width = capsule.bounds.width
        var x: CGFloat = 14
        if mode == .paused {
            playButton.frame = CGRect(x: 4, y: (height - 44) / 2, width: 44, height: 44)
            x = playButton.frame.maxX + 2
        } else {
            dot.frame = CGRect(x: x, y: (height - 10) / 2, width: 10, height: 10)
            x = dot.frame.maxX + 8
        }
        let timeW = timeLabel.sizeThatFits(CGSize(width: width, height: height)).width.rounded(.up)
        timeLabel.frame = CGRect(x: x, y: 0, width: timeW, height: height)
        let waveX = timeLabel.frame.maxX + 10
        let waveH = min(28, height - 16)
        waveform.frame = CGRect(x: waveX, y: (height - waveH) / 2,
                                width: max(0, width - trailingInset - 14 - waveX), height: waveH)
        let iconSize = trashIcon.intrinsicContentSize
        trashIcon.frame = CGRect(x: 16, y: (height - iconSize.height) / 2, width: iconSize.width,
                                 height: iconSize.height)
        releaseLabel.frame = CGRect(x: trashIcon.frame.maxX + 8, y: 0,
                                    width: max(0, width - trailingInset - trashIcon.frame.maxX - 16), height: height)
        updateWaveform()
    }
}
