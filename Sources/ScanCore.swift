// ScanCore.swift
// Shared scanning logic: drives the SANE `scanimage` tool built into
// <project>/sane-prefix and assembles scanned pages into a PDF.
//
// Used by both the SwiftUI app (App.swift) and the terminal tool (CLI.swift).

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ScanMode: String, CaseIterable, Identifiable, Sendable {
    case blackAndWhite = "Black & White"
    case gray = "Gray"
    case color = "Color"

    public var id: String { rawValue }

    /// The option value the SANE backend expects for `--mode`.
    var saneMode: String {
        switch self {
        case .blackAndWhite: return "Lineart"
        case .gray: return "Gray"
        case .color: return "Color"
        }
    }

    /// Short names accepted on the command line.
    public init?(cliName: String) {
        switch cliName.lowercased() {
        case "bw", "b&w", "lineart", "black", "blackandwhite": self = .blackAndWhite
        case "gray", "grey", "grayscale": self = .gray
        case "color", "colour": self = .color
        default: return nil
        }
    }
}

public struct ScannedPage: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let image: CGImage
    public let thumbnail: CGImage
    public let dpi: Int
    public let mode: ScanMode

    /// Page size in PDF points (1/72 inch), derived from pixels and resolution.
    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) * 72.0 / CGFloat(dpi),
               height: CGFloat(image.height) * 72.0 / CGFloat(dpi))
    }
}

public enum ScanError: LocalizedError {
    case driverNotFound
    case scannerNotFound
    case scanFailed(String)
    case timedOut
    case imageDecodeFailed
    case pdfWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .driverNotFound:
            return "Could not find the scanner driver (sane-prefix/bin/scanimage). Run driver/build-driver.sh first."
        case .scannerNotFound:
            return "No Brother HL-2280DW found. Check the USB cable and that the printer is on."
        case .scanFailed(let detail):
            return "The scan failed. \(detail)"
        case .timedOut:
            return "The scanner did not respond in time. Try turning it off and on again."
        case .imageDecodeFailed:
            return "The scanned image could not be read."
        case .pdfWriteFailed(let detail):
            return "Could not write the PDF. \(detail)"
        }
    }
}

/// Talks to the scanner via the `scanimage` command-line tool.
public final class BrotherScanner: Sendable {
    /// Physical limits of the HL-2280DW flatbed, in millimetres.
    public static let maxWidthMM = 215.9
    public static let maxHeightMM = 290.0
    public static let resolutions = [100, 150, 200, 300, 600]

    public let scanimageURL: URL

    public init() throws {
        guard let url = BrotherScanner.locateScanimage() else { throw ScanError.driverNotFound }
        scanimageURL = url
    }

    /// Finds sane-prefix/bin/scanimage: an explicit env override, or by walking
    /// up from the running executable (works for both the .app bundle and the CLI).
    static func locateScanimage() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BROTHER_SCAN_SANE_PREFIX"] {
            let url = URL(fileURLWithPath: override).appendingPathComponent("bin/scanimage")
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("sane-prefix/bin/scanimage")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("sane-prefix/bin/scanimage")
        return fm.isExecutableFile(atPath: cwd.path) ? cwd : nil
    }

    /// Returns the model name of the first scanner the driver sees, or nil.
    public func detectScanner() -> String? {
        let result = run(["-f", "%m%n"], timeout: 20)
        let name = result.stdout.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return (result.status == 0 && name?.isEmpty == false) ? name : nil
    }

    /// Scans one page from the flatbed. Blocks until the scan is complete.
    public func scanPage(mode: ScanMode, dpi: Int) throws -> ScannedPage {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brotherscan-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let args = [
            "--mode", mode.saneMode,
            "--resolution", String(dpi),
            "-x", String(BrotherScanner.maxWidthMM),
            "-y", String(BrotherScanner.maxHeightMM),
            "--format=png",
            "-o", tmp.path,
        ]

        // One retry: the scanner occasionally reports "not ready" right after a
        // previous session, or re-enumerates on USB.
        var result = run(args, timeout: 300)
        if result.status != 0 && !result.timedOut {
            Thread.sleep(forTimeInterval: 2)
            result = run(args, timeout: 300)
        }
        if result.timedOut { throw ScanError.timedOut }
        if result.status != 0 {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("No scanners were identified") || err.contains("Invalid argument") {
                throw ScanError.scannerNotFound
            }
            throw ScanError.scanFailed(err.split(separator: "\n").suffix(3).joined(separator: " "))
        }

        guard let source = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanError.imageDecodeFailed
        }
        let thumb = BrotherScanner.makeThumbnail(image, maxPixels: 400) ?? image
        return ScannedPage(image: image, thumbnail: thumb, dpi: dpi, mode: mode)
    }

    static func makeThumbnail(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let scale = min(1.0, CGFloat(maxPixels) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    struct RunResult {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    func run(_ args: [String], timeout: TimeInterval) -> RunResult {
        let process = Process()
        process.executableURL = scanimageURL
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            return RunResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        // Drain pipes on background threads so a chatty process cannot block.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        return RunResult(status: process.terminationStatus,
                         stdout: String(decoding: outData, as: UTF8.self),
                         stderr: String(decoding: errData, as: UTF8.self),
                         timedOut: timedOut)
    }
}

/// Writes the pages into a single PDF. Each page is sized from the scan's DPI so
/// a Letter-size sheet comes out as a Letter-size page. Gray and colour pages are
/// JPEG-compressed inside the PDF; black-and-white pages stay lossless.
public func writePDF(pages: [ScannedPage], to url: URL, jpegQuality: CGFloat = 0.8) throws {
    guard !pages.isEmpty else { throw ScanError.pdfWriteFailed("There are no pages to save.") }
    guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
        throw ScanError.pdfWriteFailed("Could not create \(url.lastPathComponent).")
    }
    for page in pages {
        var box = CGRect(origin: .zero, size: page.pointSize)
        let image = page.mode == .blackAndWhite ? page.image : (jpegCompressed(page.image, quality: jpegQuality) ?? page.image)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

/// Re-encodes an image as JPEG and reloads it, so Core Graphics embeds the JPEG
/// data directly in the PDF instead of a large lossless bitmap.
func jpegCompressed(_ image: CGImage, quality: CGFloat) -> CGImage? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest),
          let source = CGImageSourceCreateWithData(data, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// A default file name like "Scan 2026-09-18 22.31.pdf".
public func defaultPDFName(date: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH.mm"
    return "Scan \(f.string(from: date)).pdf"
}
