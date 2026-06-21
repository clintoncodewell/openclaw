import OpenClawChatUI
import SwiftUI
import UIKit

/// Exports a single brief / report to a polished, shareable PDF.
///
/// Rather than convert the run's markdown into HTML (lossy + a fragile hand-rolled converter), we
/// render a print-styled SwiftUI `BriefReportPage` — which reuses the SAME `OpenClawProseView`
/// markdown renderer the in-app reader uses — straight to a PDF via `ImageRenderer`. The exported
/// page is therefore the app's "nice stylesheet" itself, on a clean light document background, with
/// vector text (Text/markdown draw into the PDF context as vectors, so it stays crisp at any zoom).
enum BriefReportExporter {
    /// US-Letter content width in points (612pt page − 2×36pt margins). A fixed width gives the
    /// markdown a definite measure so `ImageRenderer` resolves a single, full-height page.
    private static let pageWidth: CGFloat = 540

    /// Render `run` to a PDF written to a temp file, returning its URL (or nil if rendering or the file
    /// write failed). Must run on the main actor — `ImageRenderer` is `@MainActor`.
    ///
    /// The report is a SINGLE continuous page sized to the content's full height (the mediaBox is the
    /// content size, so nothing is ever clipped/truncated regardless of length — a long brief just
    /// produces a tall page, which reads fine on phone/web like any scrolling document). We render at
    /// `scale = 1`: SwiftUI `Text`/markdown and shapes draw into the PDF `CGContext` as resolution-
    /// independent vectors, so a higher scale would only enlarge the backing buffer (memory) without
    /// sharpening text. The temp file lives in `temporaryDirectory`, which the OS reclaims; a same-day
    /// re-export of the same job reuses the deterministic filename (overwrite, not accrue).
    @MainActor
    static func exportPDF(run: BriefRun) -> URL? {
        let renderer = ImageRenderer(content: BriefReportPage(run: run).frame(width: pageWidth))
        renderer.scale = 1

        let pdfData = NSMutableData()
        var rendered = false
        renderer.render { size, drawInContext in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
            else {
                return
            }
            context.beginPDFPage(nil)
            drawInContext(context)
            context.endPDFPage()
            context.closePDF()
            rendered = true
        }
        guard rendered, pdfData.length > 0 else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.fileName(for: run))
        do {
            try pdfData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A filesystem-safe, human-readable export name like `morning-brief-2026-06-21.pdf`.
    private static func fileName(for run: BriefRun) -> String {
        let slugSource = run.jobName.isEmpty ? run.jobId : run.jobName
        let slug = slugSource
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, character in
                // Collapse runs of separators so the name doesn't become "a----b".
                if character == "-", partial.hasSuffix("-") { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Local formatter (export is rare): avoids a shared non-Sendable static under Swift 6 strict
        // concurrency, for a `yyyy-MM-dd` filename stamp on a fixed POSIX/gregorian basis.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: run.date)
        let base = slug.isEmpty ? "report" : slug
        return "\(base)-\(day).pdf"
    }
}

/// The print/share layout of a brief — a light, document-styled page (not the dark command-center
/// chrome) so the exported PDF reads as a clean report. Mirrors `BriefDetailScreen`'s content (title,
/// status, markdown body, run-detail footer) but tuned for a white page and a fixed width.
private struct BriefReportPage: View {
    let run: BriefRun

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            self.header
            Divider()
            if let error = self.run.error, self.run.statusKind == .error {
                self.errorBlock(error)
            }
            self.body(for: self.run.summary)
            Divider()
            self.footer
            self.watermark
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: self.run.statusKind.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(self.run.statusKind.color)
                Text(self.run.statusLabel.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(self.run.statusKind.color)
                Spacer(minLength: 0)
                Text("OpenClaw report")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(self.run.jobName)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
            Text(self.run.date.formatted(date: .complete, time: .shortened))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func errorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OpenClawBrand.danger)
            Text(error)
                .font(.callout)
                .foregroundStyle(OpenClawBrand.danger)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(OpenClawBrand.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func body(for summary: String) -> some View {
        if summary.isEmpty {
            Text("This run produced no summary.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            OpenClawProseView(text: summary)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run details")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(self.footerRows, id: \.label) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(row.value)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var watermark: some View {
        Text("Generated by OpenClaw · \(Date.now.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    /// Same run-detail rows as `BriefDetailScreen.footerRows`, kept in sync so the export matches the
    /// in-app reader.
    private var footerRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            (label: "Job", value: self.run.jobName),
            (label: "Time", value: self.run.date.formatted(date: .abbreviated, time: .standard)),
        ]
        if let provider = self.run.provider {
            let model = self.run.modelLabel
            let value = model.map { "\(provider) • \($0)" } ?? provider
            rows.append((label: "Model", value: value))
        } else if let model = self.run.modelLabel {
            rows.append((label: "Model", value: model))
        }
        if let durationLabel = self.run.durationLabel {
            rows.append((label: "Duration", value: durationLabel))
        }
        if let runId = self.run.runId {
            rows.append((label: "Run ID", value: runId))
        }
        return rows
    }
}

/// Lightweight wrapper so a freshly-exported file URL can drive a `.sheet(item:)` share presentation.
struct BriefShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Bridges `UIActivityViewController` (the system share sheet) into SwiftUI for sharing a generated
/// report file. Used over `ShareLink` because the PDF is produced on demand at tap time, not known up
/// front.
struct BriefActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: self.items, applicationActivities: nil)
        // iPad safety: if UIKit ever presents this as a popover (not the .sheet case), a popover with no
        // anchor traps with NSGenericException. Anchor it to its own view, centered with no arrow — a
        // harmless no-op on iPhone and when hosted in a sheet (where popoverPresentationController is nil).
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        guard let popover = controller.popoverPresentationController, let view = popover.sourceView else { return }
        // Center the (zero-size) source rect once the view is laid out so an iPad popover appears centered.
        popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
    }
}
