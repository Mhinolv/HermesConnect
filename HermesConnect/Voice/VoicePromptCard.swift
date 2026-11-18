import HermesKit
import SwiftUI

/// Issue #121: the buttons and fields of the card on the Voice tab.
struct VoicePromptActions {
    var choose: (ApprovalChoice) -> Void = { _ in }
    /// Send on a secret or a password. The view empties its field first.
    var sendValue: (String) -> Void = { _ in }
    /// Send on a question card: one answer for each open question, by `qid`.
    var sendAnswers: ([String: String]) -> Void = { _ in }
    var cancel: () -> Void = {}
    /// A field of the card took or lost the focus. The tab hides Mute and End while the owner types.
    var editing: (Bool) -> Void = { _ in }
}

/// Issue #121: the #104 approval card or the #117 prompt card on the Voice tab. The same model, strings, symbols and
/// colors as the chat cards: `.secondarySystemBackground`, radius 12, 44 pt buttons, Deny and Cancel red. An answer
/// here or in the chat updates both, because both read the card of the chat. The typed value lives only in the
/// field until Send or Cancel, then the field is empty.
struct VoicePromptCardView: View {
    var item: VoicePromptItem
    var phase: VoicePromptPhase
    var actions = VoicePromptActions()

    @State private var value = ""
    @State private var texts: [String: String] = [:]
    @State private var picks: [String: [String]] = [:]
    @FocusState private var focused: String?

    private static let valueKey = "value"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(Color(uiColor: .systemOrange))
            }
            .font(.subheadline.bold())
            .accessibilityAddTraits(.isHeader)
            switch item.card {
            case .approval(let card): approval(card)
            case .prompt(let card): prompt(card)
            }
            if let result = resultText {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .onChange(of: focused) { _, field in actions.editing(field != nil) }
        .onDisappear { actions.editing(false) }
    }

    private var title: String {
        switch item.card {
        case .approval: ChatApprovalCard.title
        case .prompt(let card): card.title
        }
    }

    private var symbol: String {
        switch item.card {
        case .approval: return "hand.raised.fill"
        case .prompt(let card):
            switch card.kind {
            case .secret: return "key.fill"
            case .sudo: return "lock.fill"
            case .clarify: return "questionmark.bubble.fill"
            }
        }
    }

    /// The result step of the tab, else the line of the card ("Sending…", "Not sent. Try again.").
    private var resultText: String? {
        if case .done(let text) = phase { return text }
        switch item.card {
        case .approval(let card): return card.resultText
        case .prompt(let card): return card.resultText
        }
    }

    // MARK: Approval

    @ViewBuilder private func approval(_ card: ChatApprovalCard) -> some View {
        Text(card.bodyText).font(.footnote)
        if let command = card.commandText {
            Text(command)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .accessibilityLabel("Command: \(command)")
        }
        if card.isWaiting {
            VStack(spacing: 8) {
                ForEach(card.choices, id: \.self) { choice in
                    CardButton(title: ChatApprovalCard.buttonTitle(choice), tint: choice == .deny ? .red : .blue) {
                        actions.choose(choice)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Prompt

    @ViewBuilder private func prompt(_ card: ChatPromptCard) -> some View {
        if let body = card.bodyText { Text(body).font(.footnote) }
        if let detail = card.detailText {
            Text(detail)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel(card.fieldPlaceholder == "Secret" ? "Variable: \(detail)" : "Command: \(detail)")
        }
        if card.isWaiting {
            if card.isSecure {
                SecureField(card.fieldPlaceholder, text: $value)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.send)
                    .onSubmit { send(card) }
                    .focused($focused, equals: Self.valueKey)
                    .modifier(FieldStyle())
                    .accessibilityLabel(card.fieldPlaceholder)
                    .padding(.top, 4)
            } else {
                ForEach(card.openQuestions, id: \.qid) { question in
                    Text(question.question).font(.footnote.bold()).padding(.top, 4)
                    if question.choices.isEmpty {
                        TextField("Answer", text: binding(question.qid))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focused, equals: question.qid)
                            .modifier(FieldStyle())
                            .accessibilityLabel(question.question)
                    } else {
                        ForEach(question.choices, id: \.self) { choice in
                            choiceButton(choice, question: question)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                CardButton(title: ChatPromptCard.cancelTitle, tint: .red) {
                    clear()
                    actions.cancel()
                }
                CardButton(title: ChatPromptCard.sendTitle, tint: .blue) { send(card) }
                    .disabled(!canSend(card))
            }
            .padding(.top, 6)
        }
    }

    private func binding(_ qid: String) -> Binding<String> {
        Binding { texts[qid] ?? "" } set: { texts[qid] = $0 }
    }

    private func choiceButton(_ choice: String, question: ClarifyQuestion) -> some View {
        let picked = picks[question.qid]?.contains(choice) == true
        return Button {
            var list = picks[question.qid] ?? []
            if question.multiSelect {
                if let index = list.firstIndex(of: choice) { list.remove(at: index) } else { list.append(choice) }
            } else {
                list = [choice]
            }
            picks[question.qid] = list
        } label: {
            Label(choice, systemImage: picked ? "checkmark.circle.fill" : (question.multiSelect ? "square" : "circle"))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .foregroundStyle(picked ? Color.white : Color.blue)
                .background(picked ? Color.blue : Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func typedAnswers(_ card: ChatPromptCard) -> [String: String] {
        var answers: [String: String] = [:]
        for question in card.openQuestions {
            if question.choices.isEmpty {
                answers[question.qid] = texts[question.qid] ?? ""
            } else if let picked = picks[question.qid], !picked.isEmpty {
                answers[question.qid] = question.answer(for: picked)
            }
        }
        return answers
    }

    private func canSend(_ card: ChatPromptCard) -> Bool {
        guard card.isWaiting else { return false }
        if card.isSecure { return !value.isEmpty }
        return card.clarifyAnswers(typedAnswers(card)) != nil
    }

    private func send(_ card: ChatPromptCard) {
        guard canSend(card) else { return }
        if card.isSecure {
            let sent = value
            clear()
            actions.sendValue(sent)
        } else {
            let answers = typedAnswers(card)
            clear()
            actions.sendAnswers(answers)
        }
    }

    /// Empties every field, so no field holds the value after Send or Cancel.
    private func clear() {
        value = ""
        texts = [:]
        picks = [:]
        focused = nil
    }
}

/// A 44 pt tinted button of the card, as the #104 buttons.
private struct CardButton: View {
    var title: String
    var tint: Color
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 14)
                .foregroundStyle(tint)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
