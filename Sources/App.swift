// App.swift
// A small SwiftUI app: scan pages one at a time from the HL-2280DW flatbed,
// see them pile up as thumbnails, then save everything as one PDF.

import SwiftUI
import UniformTypeIdentifiers

@main
struct BrotherScanApp: App {
    var body: some Scene {
        WindowGroup("Brother Scan") {
            ContentView()
        }
        .defaultSize(width: 920, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class ScanSession: ObservableObject {
    @Published var pages: [ScannedPage] = []
    @Published var mode: ScanMode = .gray
    @Published var dpi: Int = 300
    @Published var isScanning = false
    @Published var isChecking = false
    @Published var scannerName: String?
    @Published var status = "Looking for the scanner…"
    @Published var errorMessage: String?

    private var scanner: BrotherScanner?

    init() {
        do {
            scanner = try BrotherScanner()
            refreshScanner()
        } catch {
            status = "Driver not found"
            errorMessage = error.localizedDescription
        }
    }

    func refreshScanner() {
        guard let scanner, !isChecking else { return }
        isChecking = true
        Task.detached {
            let name = scanner.detectScanner()
            await MainActor.run {
                self.scannerName = name
                self.status = name.map { "\($0) connected. Place a page on the glass." }
                    ?? "Scanner not found. Check USB and power, then press Refresh."
                self.isChecking = false
            }
        }
    }

    func scanNextPage() {
        guard let scanner, !isScanning else { return }
        isScanning = true
        let pageNumber = pages.count + 1
        let mode = self.mode, dpi = self.dpi
        status = "Scanning page \(pageNumber)…"
        Task.detached {
            do {
                let page = try scanner.scanPage(mode: mode, dpi: dpi)
                await MainActor.run {
                    self.pages.append(page)
                    self.scannerName = self.scannerName ?? "Brother HL-2280DW"
                    self.status = "Page \(pageNumber) scanned. Place the next page, or save the PDF."
                    self.isScanning = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.status = "Page \(pageNumber) failed."
                    self.isScanning = false
                    if case ScanError.scannerNotFound = error { self.scannerName = nil }
                }
            }
        }
    }

    func removeLastPage() { if !pages.isEmpty { pages.removeLast() } }
    func remove(_ page: ScannedPage) { pages.removeAll { $0.id == page.id } }
    func clearAll() { pages.removeAll() }

    func savePDF() {
        guard !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultPDFName()
        panel.canCreateDirectories = true
        panel.title = "Save Scanned PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writePDF(pages: pages, to: url)
            status = "Saved \(pages.count) page\(pages.count == 1 ? "" : "s") to \(url.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var session = ScanSession()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            pageArea
        }
        .alert("Scanning problem", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Brother HL-2280DW").font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(session.scannerName != nil ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    Text(session.scannerName != nil ? "Connected (USB)" : "Not found")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        session.refreshScanner()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.isChecking || session.isScanning)
                    .help("Look for the scanner again")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker("Mode", selection: $session.mode) {
                    ForEach(ScanMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Resolution", selection: $session.dpi) {
                    ForEach(BrotherScanner.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }
            }
            .disabled(session.isScanning)

            Divider()

            Button {
                session.scanNextPage()
            } label: {
                HStack {
                    if session.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "scanner")
                    }
                    Text(session.isScanning ? "Scanning…" : "Scan Page \(session.pages.count + 1)")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(session.isScanning)

            Button {
                session.savePDF()
            } label: {
                HStack {
                    Image(systemName: "doc.richtext")
                    Text("Save PDF…")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(session.pages.isEmpty || session.isScanning)

            HStack {
                Button("Remove Last") { session.removeLastPage() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Clear All") { session.clearAll() }
            }
            .disabled(session.pages.isEmpty || session.isScanning)

            Spacer()

            Text(session.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Return = scan next page · ⌘S = save PDF")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var pageArea: some View {
        Group {
            if session.pages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                    Text("No pages yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Put the first page face down on the glass and press Return.")
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], spacing: 20) {
                        ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                            VStack(spacing: 6) {
                                Image(decorative: page.thumbnail, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 220)
                                    .shadow(radius: 3, y: 1)
                                HStack {
                                    Text("Page \(index + 1)").font(.callout)
                                    Text("· \(page.dpi) dpi").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                Button("Remove Page \(index + 1)", role: .destructive) { session.remove(page) }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
