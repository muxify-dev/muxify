import SwiftUI

/// What a find bar searches: a Tab's page (Find in Page) or a Pane's history (Find in Pane).
@MainActor protocol Finder: AnyObject, Observable {
    var findQuery: String { get set }
    var findStatus: FindStatus { get }
    /// The bar moves Focus to its field and selects its text.
    var findFieldFocusRequested: Bool { get set }
    /// The field has Focus, so the keybinds of `keybindings.find` act.
    var findFieldHasFocus: Bool { get set }
    func findNext()
    func findPrevious()
}

enum FindStatus: Equatable {
    case idle
    case notFound
    /// `index` is 0-based.
    case match(index: Int, total: Int)
}

/// The find field, the number of the current match, and Find Previous, Find Next and Done. Its identifiers start
/// with `identifier`, such as `browser-find-field`. The keys of the field are `keybindings.find`, which the App
/// Window's key monitor runs while `findFieldHasFocus`.
struct FindBar<Target: Finder>: View {
    @Bindable var finder: Target
    let placeholder: String
    let identifier: String
    /// The window of the field, to select its text.
    let window: () -> NSWindow?
    let onClose: () -> Void
    var onFieldFocus: (Bool) -> Void = { _ in }

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $finder.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($fieldFocused)
                .accessibilityIdentifier(identifier + "-field")
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier(identifier + "-status")
            HStack(spacing: 2) {
                Button(action: finder.findPrevious) { Image(systemName: "chevron.left") }
                    .help("Find Previous")
                    .accessibilityLabel("Find Previous")
                    .accessibilityIdentifier(identifier + "-previous")
                Button(action: finder.findNext) { Image(systemName: "chevron.right") }
                    .help("Find Next")
                    .accessibilityLabel("Find Next")
                    .accessibilityIdentifier(identifier + "-next")
            }
            .disabled(finder.findQuery.isEmpty)
            Spacer(minLength: 0)
            Button("Done", action: onClose)
                .accessibilityIdentifier(identifier + "-done")
        }
        .controlSize(.small)
        .onAppear(perform: consumeFocusRequest)
        .onChange(of: finder.findFieldFocusRequested) { _, _ in consumeFocusRequest() }
        .onChange(of: fieldFocused) { _, focused in
            finder.findFieldHasFocus = focused
            onFieldFocus(focused)
        }
    }

    private var status: String {
        switch finder.findStatus {
        case .idle: ""
        case .notFound: "Not found"
        case let .match(index, total): "\(index + 1) of \(total)"
        }
    }

    private func consumeFocusRequest() {
        guard finder.findFieldFocusRequested else { return }
        finder.findFieldFocusRequested = false
        DispatchQueue.main.async {
            fieldFocused = true
            DispatchQueue.main.async { (window()?.firstResponder as? NSText)?.selectAll(nil) }
        }
    }
}
