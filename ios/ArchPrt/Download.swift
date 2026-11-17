import Compression
import Foundation
import UIKit

/// The prebuilt Arch guest from this repo's "guest" release (CI: guest job), xz-compressed.
extension VM {
    static let guestBase = URL(string: "https://github.com/neosay-dev/archprt/releases/download/guest/")!

    func download() {
        if case .downloading = state { return }
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                for (i, name) in VM.guestFiles.enumerated() {
                    let dst = docs.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: dst.path) { continue }
                    let step = "\(i + 1) из \(VM.guestFiles.count)"
                    let xz = try await fetch(VM.guestBase.appendingPathComponent(name + ".xz"), step: step)
                    defer { try? FileManager.default.removeItem(at: xz) }
                    try await unpack(xz, to: dst, step: step)
                }
                await MainActor.run {
                    UIApplication.shared.isIdleTimerDisabled = false
                    state = .ready
                }
            } catch {
                await MainActor.run {
                    UIApplication.shared.isIdleTimerDisabled = false
                    state = .needsDownload(error: error.localizedDescription)
                }
            }
        }
    }

    private func fetch(_ url: URL, step: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                observation?.invalidate()
                if let error { return cont.resume(throwing: error) }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return cont.resume(throwing: DownloadError("Сервер ответил \((response as? HTTPURLResponse)?.statusCode ?? 0) на \(url.lastPathComponent)"))
                }
                // URLSession deletes `tmp` when this handler returns.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: tmp, to: kept)
                    cont.resume(returning: kept)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                let mb = { (b: Int64) in b / 1_000_000 }
                let text = "Скачивание \(step): \(mb(task.countOfBytesReceived)) из \(mb(max(task.countOfBytesExpectedToReceive, 0))) МБ"
                DispatchQueue.main.async { self?.state = .downloading(step: text, progress: p.fractionCompleted) }
            }
            task.resume()
        }
    }

    /// shortcut: xz has its own CRC but no signature check; fine while the URL is our HTTPS release, add a hash manifest if mirrors appear.
    private func unpack(_ xz: URL, to dst: URL, step: String) async throws {
        let part = dst.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let total = Double((try? xz.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1)
        try await Task.detached(priority: .userInitiated) { [weak self] in
            let input = try FileHandle(forReadingFrom: xz)
            let output = try FileHandle(forWritingTo: part)
            defer { try? input.close(); try? output.close() }
            let filter = try OutputFilter(.decompress, using: .lzma) { data in
                if let data { try output.write(contentsOf: data) }
            }
            var read = 0.0
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try filter.write(chunk)
                read += Double(chunk.count)
                let p = read / total
                DispatchQueue.main.async { self?.state = .downloading(step: "Распаковка \(step)", progress: p) }
            }
            try filter.finalize()
        }.value
        try FileManager.default.moveItem(at: part, to: dst)
    }
}

struct DownloadError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
