import Compression
import CryptoKit
import Foundation
import UIKit

/// The prebuilt Arch guest from this repo's "guest" release (CI: guest job), xz-compressed.
extension VM {
    static let guestBase = URL(string: "https://github.com/neosay-dev/archprt/releases/download/guest/")!

    /// Written once every guest file matched MANIFEST; later the disk changes (grow, guest writes) and isn't re-checked.
    var verifiedMarker: URL { docs.appendingPathComponent(".verified") }

    /// Brings Documents to a verified guest: checks files already there (older installs), downloads missing or broken ones.
    func download() {
        if case .downloading = state { return }
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                let manifest = try await fetchManifest()
                for (i, name) in VM.guestFiles.enumerated() {
                    let dst = docs.appendingPathComponent(name)
                    let step = "\(i + 1) из \(VM.guestFiles.count)"
                    guard let want = manifest[name] else { throw DownloadError("\(name) нет в MANIFEST") }
                    if FileManager.default.fileExists(atPath: dst.path) {
                        if try await matches(dst, want, step: step) { continue }
                        try FileManager.default.removeItem(at: dst)
                    }
                    let xz = try await fetch(VM.guestBase.appendingPathComponent(name + ".xz"), step: step)
                    defer { try? FileManager.default.removeItem(at: xz) }
                    try await unpack(xz, to: dst, step: step)
                    guard try await matches(dst, want, step: step) else {
                        try? FileManager.default.removeItem(at: dst)
                        throw DownloadError("\(name) распаковался с ошибкой (контрольная сумма не совпала)")
                    }
                }
                FileManager.default.createFile(atPath: verifiedMarker.path, contents: nil)
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

    /// MANIFEST lines: "<sha256> <size> <name>" (guest.yml).
    private func fetchManifest() async throws -> [String: (sha: String, size: Int64)] {
        let (data, response) = try await URLSession.shared.data(from: VM.guestBase.appendingPathComponent("MANIFEST"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError("Нет MANIFEST в релизе guest") }
        var out: [String: (sha: String, size: Int64)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 3, let size = Int64(f[1]) { out[String(f[2])] = (String(f[0]), size) }
        }
        return out
    }

    /// Size first (a grown 16 GB disk fails instantly), then SHA-256.
    private func matches(_ file: URL, _ want: (sha: String, size: Int64), step: String) async throws -> Bool {
        let size = Int64((try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        guard size == want.size else { return false }
        return try await Task.detached(priority: .userInitiated) { [weak self] in
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var hash = SHA256()
            var done = 0.0
            while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
                hash.update(data: chunk)
                done += Double(chunk.count)
                let p = done / Double(max(size, 1))
                DispatchQueue.main.async { self?.state = .downloading(step: "Проверка \(step)", progress: p) }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == want.sha
        }.value
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
