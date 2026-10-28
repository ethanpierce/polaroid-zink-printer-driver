import AppKit
import SwiftUI
import ZipPrinterKit

@main
struct ZipPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("ZIP Print", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("Print") { model.print() }
                    .keyboardShortcut("p")
                    .disabled(!model.canPrint)
            }
            CommandMenu("Printer") {
                Button("Find Printers") { model.scan() }
                    .keyboardShortcut("r")
                Divider()
                Toggle("Show in Print Dialog", isOn: Binding(
                    get: { model.isInPrintMenu },
                    set: { _ in model.togglePrintMenu() }
                ))
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--verbose") {
            ZipLog.handler = { message in
                AppModel.shared.log(Date().formatted(date: .omitted, time: .standard) + "  " + message)
            }
        }
        Task { @MainActor in
            if let status = await AppModel.shared.runCommandLine(CommandLine.arguments) {
                exit(status)
            }
        }
    }

    /// Files dropped on the Dock icon, opened with "Open With", or sent from
    /// the Print dialog's PDF menu.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in AppModel.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
