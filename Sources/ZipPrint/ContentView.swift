import SwiftUI
import ZipPrinterKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            PrinterBar()
            Divider()
            PreviewCard()
            Controls()
            PrintButton()
            StatusLine()
        }
        .padding(20)
        .frame(width: 340)
        .task { await model.start() }
    }
}

// MARK: - Printer

private struct PrinterBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "printer.fill")
                .font(.title2)
                .foregroundStyle(model.selectedPrinter == nil ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                if model.printers.isEmpty {
                    Text(model.isScanning ? "Looking for printers…" : "No printer found")
                        .font(.headline)
                    Text("Switch the ZIP on and keep it nearby.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Printer", selection: $model.selectedAddress) {
                        ForEach(model.printers) { printer in
                            Text(printer.name).tag(Optional(printer.address))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    PrinterStatusLabel(status: model.printerStatus)
                        .help(model.selectedAddress ?? "")
                }
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button { model.scan() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Find printers")
                .disabled(model.isBusy)
            }
        }
    }
}

private struct PrinterStatusLabel: View {
    let status: AppModel.PrinterStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var color: Color {
        switch status {
        case .unknown: return .gray
        case .ready: return .green
        case .asleep: return .orange
        }
    }

    private var label: String {
        switch status {
        case .unknown: return "Checking…"
        case .ready: return "Ready"
        case .asleep: return "Asleep. Press the printer's power button."
        }
    }
}

// MARK: - Preview

private struct PreviewCard: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false
    @State private var dragStart: CGPoint?

    private let size = CGSize(width: 200, height: 300)

    var body: some View {
        ZStack {
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .gesture(model.options.layout == .fill ? reposition : nil)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                    Text("Drop a photo or PDF here\nor click to choose")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
                .contentShape(Rectangle())
                .onTapGesture { model.showOpenPanel() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isTargeted ? Color.accentColor : .secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: isTargeted ? 3 : 1, dash: model.preview == nil ? [6] : []))
        )
        .shadow(color: .black.opacity(model.preview == nil ? 0 : 0.25), radius: 8, y: 3)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .help(model.options.layout == .fill && model.preview != nil ? "Drag to reposition the crop" : "")
    }

    /// Dragging the photo slides the crop window across the overflowing axis.
    private var reposition: some Gesture {
        DragGesture()
            .onChanged { value in
                guard let image = model.sourceImage else { return }
                let start = dragStart ?? model.options.focus
                if dragStart == nil { dragStart = start }
                let landscape = image.width > image.height
                let turns = (model.options.autoRotate && landscape ? 1 : 0) + model.options.quarterTurns
                let source = turns % 2 == 1
                    ? CGSize(width: image.height, height: image.width)
                    : CGSize(width: image.width, height: image.height)
                let scale = max(size.width / source.width, size.height / source.height)
                let overflow = CGSize(width: source.width * scale - size.width, height: source.height * scale - size.height)
                var focus = start
                if overflow.width > 1 { focus.x = clamp(start.x - 2 * value.translation.width / overflow.width) }
                if overflow.height > 1 { focus.y = clamp(start.y - 2 * value.translation.height / overflow.height) }
                model.options.focus = focus
            }
            .onEnded { _ in dragStart = nil }
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, -1), 1) }
}

// MARK: - Controls

private struct Controls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if let name = model.fileName {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Picker("Layout", selection: $model.options.layout) {
                    Text("Fill").tag(PrintImage.Layout.fill)
                    Text("Fit").tag(PrintImage.Layout.fit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                .help("Fill crops the photo to cover the sheet; Fit shows all of it with white borders")

                Button { model.rotate() } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate 90°")

                Spacer()

                Button("Choose…") { model.showOpenPanel() }
            }
            .disabled(model.isBusy)
        }
    }
}

// MARK: - Print

private struct PrintButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.print() } label: {
            Label("Print", systemImage: "printer")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut("p")
        .disabled(!model.canPrint)
    }
}

private struct StatusLine: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.job {
            case .idle:
                if model.selectedAddress == nil {
                    Text("Find your printer to get started.")
                } else if model.preview == nil {
                    Text("Choose a photo to print.")
                } else {
                    Text("Ready to print on 2×3\" ZINK paper.")
                }
            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to printer…")
                }
            case let .sending(fraction):
                VStack(spacing: 4) {
                    ProgressView(value: fraction)
                    Text("Sending photo… \(Int(fraction * 100))%")
                }
            case .sent:
                Label("Sent! Your print will come out in about a minute.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 36)
        .fixedSize(horizontal: false, vertical: true)
    }
}
