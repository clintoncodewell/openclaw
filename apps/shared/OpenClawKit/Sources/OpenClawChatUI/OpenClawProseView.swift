import SwiftUI

/// Public wrapper around the internal `ChatMarkdownRenderer` so app targets can render
/// assistant-style markdown (headings, lists, GitHub tables, code) without taking a direct
/// dependency on the private `Textual` library. Keeps `Textual` and `ChatMarkdownRenderer`
/// internal to this module while exposing only the rendered view surface callers actually need.
@MainActor
public struct OpenClawProseView: View {
    private let text: String
    private let font: Font
    private let textColor: Color

    public init(
        text: String,
        font: Font = .body,
        textColor: Color = .primary)
    {
        self.text = text
        self.font = font
        self.textColor = textColor
    }

    public var body: some View {
        ChatMarkdownRenderer(
            text: self.text,
            context: .assistant,
            variant: .standard,
            font: self.font,
            textColor: self.textColor)
    }
}
