import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZipPrinterKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum JobState: Equatable {
        case idle
        case connecting
        case sending(Double)
        case sent
        case failed(String)
    }

    enum PrinterStatus: Equatable {
        case unknown
        case ready
        case asleep
    }

    // Printers
    @Published private(set) var printers: [DiscoveredPrinter] = []
    @Published private(set) var isScanning = false
    @Published var selectedAddress: String? {
        didSet {
            UserDefaults.standard.set(selectedAddress, forKey: "printerAddress")
            UserDefaults.standard.set(selectedPrinter?.name, forKey: "printerName")
            if selectedAddress != oldValue {
                printerStatus = .unknown
                restartStatusChecks()
            }
        }
    }
    @Published private(set) var printerStatus = PrinterStatus.unknown

    // Document
    @Published private(set) var sourceImage: CGImage?
    @Published private(set) var fileName: String?
    @Published private(set) var preview: CGImage?
    @Published var options = PrintImage.Options() {
        didSet { if options != oldValue { renderPreview() } }
    }

    // Job
    @Published private(set) var job: JobState = .idle

    private let browser = PrinterBrowser()
    private var bluetoothReady = false
    private var statusTask: Task<Void, Never>?
    private var isPinging = false
    private var lastPrint = Date.distantPast
    private var isCommandLine = false

    /// How often to check whether the printer is reachable. The ZIP powers
    /// itself off after about five idle minutes, and these checks don't
    /// count as activity, but they let the window notice when it's switched
    /// back on.
    static let statusInterval: TimeInterval = 45

    static let openableTypes: [UTType] = [.image, .pdf]

    init() {
        let defaults = UserDefaults.standard
        if let address = defaults.string(forKey: "printerAddress") {
            printers = [DiscoveredPrinter(address: address, name: defaults.string(forKey: "printerName") ?? "Polaroid ZIP")]
            selectedAddress = address
        }
        browser.onChange = { [weak self] in self?.syncBrowser() }
    }

    /// Brings up Bluetooth and looks for printers if none is known yet.
    func start() async {
        await ensureBluetooth()
        if selectedAddress == nil && !isScanning { scan() }
        restartStatusChecks()
    }

    private func ensureBluetooth() async {
        guard !bluetoothReady else { return }
        await PrinterBrowser.prepareBluetooth()
        bluetoothReady = true
        for printer in browser.knownPrinters() where !printers.contains(where: { $0.address == printer.address }) {
            printers.append(printer)
        }
        if selectedAddress == nil { selectedAddress = printers.first?.address }
    }

    var selectedPrinter: DiscoveredPrinter? {
        printers.first { $0.address == selectedAddress }
    }

    var isBusy: Bool {
        switch job {
        case .connecting, .sending: return true
        default: return false
        }
    }

    var canPrint: Bool { preview != nil && selectedAddress != nil && !isBusy }

    // MARK: Printers

    func scan() {
        Task {
            await ensureBluetooth()
            browser.startScan()
            syncBrowser()
        }
    }

    private func syncBrowser() {
        var merged = browser.printers
        if let saved = selectedAddress, let current = printers.first(where: { $0.address == saved }),
           !merged.contains(where: { $0.address == saved }) {
            merged.insert(current, at: 0)
        }
        printers = merged
        isScanning = browser.isScanning
        if selectedAddress == nil { selectedAddress = printers.first?.address }
    }

    // MARK: Printer status

    private func restartStatusChecks() {
        statusTask?.cancel()
        guard bluetoothReady, !isCommandLine else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkPrinter()
                try? await Task.sleep(nanoseconds: UInt64(Self.statusInterval * 1_000_000_000))
            }
        }
    }

    private func checkPrinter() async {
        // Skip while printing, and while the printer is still busy with the
        // last print (it counts as activity anyway).
        guard let address = selectedAddress, !isBusy, !isScanning,
              Date().timeIntervalSince(lastPrint) > 90,
              let printer = ZipPrinter(address: address) else { return }
        isPinging = true
        defer { isPinging = false }
        do {
            try await printer.ping()
            if selectedAddress == address { printerStatus = .ready }
        } catch {
            if selectedAddress == address { printerStatus = .asleep }
        }
    }

    // MARK: Document

    func open(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = PrintImage.load(url) else {
            job = .failed(ZipPrinterError.unreadableFile(url).localizedDescription)
            return
        }
        sourceImage = image
        fileName = url.lastPathComponent
        options.focus = .zero
        options.quarterTurns = 0
        job = .idle
        renderPreview()
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openableTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo or PDF to print"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func rotate() {
        options.quarterTurns = (options.quarterTurns + 1) % 4
        options.focus = .zero
    }

    private func renderPreview() {
        guard let sourceImage else { preview = nil; return }
        preview = PrintImage.render(sourceImage, options: options)
    }

    // MARK: Printing

    func print() {
        Task { await printNow() }
    }

    func printNow() async {
        guard canPrint, let preview, let address = selectedAddress else { return }
        browser.stopScan()
        guard let jpeg = PrintImage.jpegData(preview) else {
            job = .failed("Couldn't encode the photo.")
            return
        }
        job = .connecting
        await ensureBluetooth()
        while isPinging { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let printer = ZipPrinter(address: address) else {
            job = .failed("\(address) isn't a valid Bluetooth address.")
            return
        }
        do {
            try await printer.send(jpeg: jpeg, fileName: "zipprint.jpg") { [weak self] fraction in
                self?.job = .sending(fraction)
            }
            job = .sent
            printerStatus = .ready
            lastPrint = Date()
        } catch {
            job = .failed(error.localizedDescription)
        }
    }

    // MARK: Print dialog integration

    static var pdfServiceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/PDF Services/Print to Polaroid ZIP.app")
    }

    var isInPrintMenu: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: Self.pdfServiceURL.path)) == Bundle.main.bundlePath
    }

    /// Adds "Print to Polaroid ZIP" to the PDF menu of every app's Print
    /// dialog. macOS opens the printed PDF in this app.
    func togglePrintMenu() {
        let fm = FileManager.default
        let link = Self.pdfServiceURL
        do {
            if isInPrintMenu {
                try fm.removeItem(at: link)
            } else {
                try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: Bundle.main.bundlePath)
            }
        } catch {
            job = .failed("Couldn't update the Print menu: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    // MARK: Command line

    /// `ZipPrint --print FILE [--printer ADDRESS]`: prints FILE and quits.
    /// Exit status is 0 once the printer has accepted the photo.
    func runCommandLine(_ args: [String]) async -> Int32? {
        guard let i = args.firstIndex(of: "--print"), i + 1 < args.count else { return nil }
        let url = URL(fileURLWithPath: args[i + 1])
        isCommandLine = true
        statusTask?.cancel()
        if let p = args.firstIndex(of: "--printer"), p + 1 < args.count {
            let address = args[p + 1]
            if !printers.contains(where: { $0.address == address }) {
                printers.append(DiscoveredPrinter(address: address, name: "Polaroid ZIP"))
            }
            selectedAddress = address
        }
        await ensureBluetooth()
        if selectedAddress == nil {
            log("Looking for a printer…")
            scan()
            for _ in 0..<60 where selectedAddress == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard let address = selectedAddress else {
            log("No printer found. Switch the ZIP on and try again.")
            return 2
        }
        open(url)
        guard preview != nil else {
            log(ZipPrinterError.unreadableFile(url).localizedDescription)
            return 3
        }
        log("Printing \(url.lastPathComponent) on \(selectedPrinter?.name ?? address) (\(address))…")
        await printNow()
        switch job {
        case .sent:
            log("Sent. The print will come out in about a minute.")
            return 0
        case let .failed(message):
            log("Failed: \(message)")
            return 1
        default:
            return 1
        }
    }

    func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
}
