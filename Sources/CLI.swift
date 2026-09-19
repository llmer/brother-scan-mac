// CLI.swift
// Terminal version: scan pages one at a time and write a single PDF.
//
//   scan-cli [--mode bw|gray|color] [--dpi 300] [--pages N] output.pdf
//
// Without --pages it keeps asking for pages until you type "done".

import Foundation

@main
struct ScanCLI {
    static func usage() -> Never {
        let text = """
        usage: scan-cli [--mode bw|gray|color] [--dpi 100|150|200|300|600] [--pages N] output.pdf

          --mode    Black & white (bw), grayscale (gray, default) or color.
          --dpi     Resolution in dots per inch (default 300).
          --pages   Stop automatically after N pages. Otherwise press Return for
                    each page and type "done" to finish.
        """
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
        exit(2)
    }

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        var mode: ScanMode = .gray
        var dpi = 300
        var pageLimit: Int?
        var output: String?

        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--mode", "-m":
                guard let v = args.first, let m = ScanMode(cliName: v) else { usage() }
                args.removeFirst(); mode = m
            case "--dpi", "-r", "--resolution":
                guard let v = args.first, let d = Int(v), BrotherScanner.resolutions.contains(d) else { usage() }
                args.removeFirst(); dpi = d
            case "--pages", "-n":
                guard let v = args.first, let n = Int(v), n > 0 else { usage() }
                args.removeFirst(); pageLimit = n
            case "-h", "--help":
                usage()
            default:
                if a.hasPrefix("-") || output != nil { usage() }
                output = a
            }
        }
        guard let output else { usage() }
        let outURL = URL(fileURLWithPath: output)

        let scanner: BrotherScanner
        do { scanner = try BrotherScanner() } catch {
            fail(error.localizedDescription)
        }

        print("Looking for the scanner…", terminator: " ")
        fflush(stdout)
        guard let name = scanner.detectScanner() else {
            print()
            fail(ScanError.scannerNotFound.localizedDescription)
        }
        print("found \(name).")
        print("Mode: \(mode.rawValue), \(dpi) dpi. Output: \(outURL.path)")

        var pages: [ScannedPage] = []
        while true {
            let n = pages.count + 1
            if let limit = pageLimit, pages.count >= limit { break }
            if pageLimit == nil {
                print("\nPlace page \(n) on the glass and press Return (or type \"done\"): ", terminator: "")
            } else {
                print("\nPlace page \(n) of \(pageLimit!) on the glass and press Return: ", terminator: "")
            }
            fflush(stdout)
            guard let line = readLine() else { break }
            let cmd = line.trimmingCharacters(in: .whitespaces).lowercased()
            if cmd == "done" || cmd == "d" || cmd == "q" { break }

            print("Scanning page \(n)…", terminator: " ")
            fflush(stdout)
            do {
                let page = try scanner.scanPage(mode: mode, dpi: dpi)
                pages.append(page)
                print("ok (\(page.image.width)×\(page.image.height) px)")
            } catch {
                print("failed")
                print("  \(error.localizedDescription)")
                print("  Press Return to retry this page, or type \"done\" to stop.")
            }
        }

        guard !pages.isEmpty else {
            print("No pages scanned; nothing written.")
            exit(1)
        }
        do {
            try writePDF(pages: pages, to: outURL)
            print("\nWrote \(pages.count) page\(pages.count == 1 ? "" : "s") to \(outURL.path)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
