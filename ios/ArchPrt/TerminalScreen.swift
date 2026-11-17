import SwiftTerm
import SwiftUI
import UIKit

/// The guest's hvc0 console. SwiftTerm brings the key bar (Esc, Ctrl, Tab, arrows, F-keys) and hardware keyboard support.
struct TerminalScreen: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        tv.terminalDelegate = context.coordinator
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        tv.keyboardAppearance = .dark
        VM.shared.onOutput = { [weak tv] bytes in tv?.feed(byteArray: bytes) }
        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    final class Coordinator: TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) { VM.shared.write(data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { VM.shared.resize(cols: newCols, rows: newRows) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
