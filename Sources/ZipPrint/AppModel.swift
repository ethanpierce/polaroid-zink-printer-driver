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
        case retrying(attempt: Int, of: Int)
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
            // A printer chosen with --printer is for that one print only.
            if !isCommandLine {
                UserDefaults.standard.set(selectedAddress, forKey: "printerAddress")
                UserDefaults.standard.set(selectedPrinter?.name, forKey: "printerName")
            }
            if selectedAddress != oldValue {
                printerStatus = .unknown
                restartStatusChecks()
            }
        }
    }
    @Published private(set) var printerStatus = PrinterStatus.unknown
    @Published private(set) var isConnecting = false

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
    private var printTask: Task<Void, Never>?
    private var isPinging = false
    private var lastPrint = Date.distantPast
    private var isCommandLine = false

    /// How often to check whether the printer is reachable. The ZIP powers
    /// itself off after a few idle minutes, and these checks don't count as
    /// activity, but they let the window notice when it's switched back on.
    static let statusInterval: TimeInterval = 45
    static let asleepStatusInterval: TimeInterval = 15

    /// How many times to try reaching the printer before giving up on a
    /// print. Each try waits up to about 12 seconds for the printer.
    static let printAttempts = 5

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
        case .connecting, .retrying, .sending: return true
        default: return false
        }
    }

    var canPrint: Bool { preview != nil && selectedAddress != nil && !isBusy }

    /// A print can be cancelled until the photo starts sending.
    var canCancel: Bool {
        switch job {
        case .connecting, .retrying: return true
        default: return false
        }
    }

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
                let interval = self.printerStatus == .ready ? Self.statusInterval : Self.asleepStatusInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Checks the printer now, when the user asks to connect.
    func connect() {
        // A check already under way answers the same question.
        guard !isPinging else {
            isConnecting = true
            return
        }
        Task {
            await ensureBluetooth()
            await checkPrinter(manual: true)
        }
    }

    private func checkPrinter(manual: Bool = false) async {
        // Skip while printing, and (unless asked) while the printer is still
        // busy with the last print, which counts as activity anyway.
        guard let address = selectedAddress, !isBusy, !isScanning, !isPinging,
              manual || Date().timeIntervalSince(lastPrint) > 90,
              let printer = ZipPrinter(address: address) else { return }
        isPinging = true
        isConnecting = manual
        defer {
            isPinging = false
            isConnecting = false
        }
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
        show(image, name: url.lastPathComponent)
    }

    /// Uses the photo on the clipboard: an image, or a file copied in Finder.
    func paste() {
        guard !isBusy else { return }
        guard let (image, name) = PrintImage.load(from: .general) else {
            job = .failed("There's no photo on the clipboard.")
            return
        }
        show(image, name: name)
    }

    private func show(_ image: CGImage, name: String) {
        sourceImage = image
        fileName = name
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
        printTask = Task { await printNow() }
    }

    func cancelPrint() {
        guard canCancel else { return }
        printTask?.cancel()
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
            try await printer.send(jpeg: jpeg, fileName: "zipprint.jpg", retries: Self.printAttempts - 1,
                                   onRetry: { [weak self] attempt in
                                       self?.job = .retrying(attempt: attempt, of: Self.printAttempts)
                                       if self?.isCommandLine == true {
                                           self?.log("Can't reach the printer. Trying again (\(attempt) of \(Self.printAttempts))…")
                                       }
                                   }) { [weak self] fraction in
                self?.job = .sending(fraction)
            }
            job = .sent
            printerStatus = .ready
            lastPrint = Date()
        } catch is CancellationError {
            job = .idle
        } catch {
            if case .timeout = error as? ZipPrinterError { printerStatus = .asleep }
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
