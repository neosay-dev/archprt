import Foundation

/// The Arch guest: one QEMU per app run (QEMU can't be re-initialised in the same process).
final class VM: ObservableObject {
    static let shared = VM()

    enum State: Equatable {
        case needsDownload(error: String?)
        case downloading(step: String, progress: Double)
        case ready
        case noJIT
        case booting
        case running
        case stopped(String)
    }

    @Published var state: State = .booting
    /// Console bytes for the terminal; set on the main thread.
    var onOutput: ((ArraySlice<UInt8>) -> Void)? {
        didSet { if let onOutput, !pending.isEmpty { onOutput(pending[...]); pending.removeAll() } }
    }

    private var pending: [UInt8] = []
    /// Boot messages for the loading screen (ANSI stripped, last ~12 KB).
    @Published private(set) var bootLog = ""
    private(set) var bootStarted = Date()
    private var markerTail: [UInt8] = []
    private static let loginMarker = Array("(automatic login)".utf8)
    private var console: Int32 = -1
    private var resizer: Int32 = -1
    private var size = (cols: 80, rows: 24)

    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    private var started = false

    /// Guest files in Documents; the downloader only creates them complete (renamed from .part).
    static let guestFiles = ["Image", "initramfs.img", "arch.img"]
    var guestInstalled: Bool { VM.guestFiles.allSatisfy { FileManager.default.fileExists(atPath: docs.appendingPathComponent($0).path) } }

    /// App launch: boot right away if Arch is downloaded, otherwise offer the download.
    func launch() {
        guard state == .booting else { return }
        if guestInstalled && FileManager.default.fileExists(atPath: verifiedMarker.path) { start() }
        else if guestInstalled { download() }  // installed before checksums existed: verify first
        else { state = .needsDownload(error: nil) }
    }

    func start() {
        guard !started else { return }
        guard archprt_jit_enabled() != 0 else { state = .noJIT; return }
        started = true
        state = .booting
        do {
            try growDisk()
        } catch {
            state = .stopped("Не удалось подготовить диск: \(error.localizedDescription)")
            return
        }
        let consolePath = tmp.appendingPathComponent("c").path
        let resizePath = tmp.appendingPathComponent("r").path
        let serialPath = tmp.appendingPathComponent("s").path
        let args = arguments(console: consolePath, resize: resizePath, serial: serialPath)
        let dylib = Bundle.main.privateFrameworksPath! + "/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
        var cargs = args.map { strdup($0) }
        defer { cargs.forEach { free($0) } }
        let err = cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                archprt_qemu_start(dylib, Int32(buf.count), $0) { status in
                    DispatchQueue.main.async { VM.shared.state = .stopped(status == 0 ? "Arch выключен." : "QEMU завершился с ошибкой (\(status)). Подробности в Файлах: ArchPrt → boot.log") }
                }
            }
        }
        if let err {
            state = .stopped("QEMU не запустился: \(String(cString: err))")
            return
        }
        Thread.detachNewThread { self.pump(path: consolePath) }
        Thread.detachNewThread { self.handshake(path: resizePath) }
        Thread.detachNewThread { self.serialLog(path: serialPath) }
        bootStarted = Date()
        // earlycon prints within a second even under TCG: total silence means the CPU loop isn't running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            guard self.state == .booting, self.bootLog.isEmpty else { return }
            self.state = .stopped("Ядро не написало ни строчки за 45 секунд. Скорее всего, JIT не работает на этой версии iOS (или StikDebug отключился от приложения). Пришли скрин этого экрана и ArchPrt → boot.log из «Файлов».")
        }
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        guard console >= 0 else { return }
        bytes.withUnsafeBytes { _ = Darwin.write(console, $0.baseAddress, $0.count) }
    }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        sendSize()
    }

    // MARK: - Disk

    /// Sparse grow; the guest's archprt-grow.service stretches ext4 to it on boot.
    private func growDisk() throws {
        let disk = try FileHandle(forWritingTo: docs.appendingPathComponent("arch.img"))
        defer { try? disk.close() }
        if try disk.seekToEnd() < 16 << 30 { try disk.truncate(atOffset: 16 << 30) }
    }

    private func arguments(console: String, resize: String, serial: String) -> [String] {
        let cores = min(ProcessInfo.processInfo.activeProcessorCount, 4)
        return [
            "qemu-system-aarch64",
            "-M", "virt",
            // Cortex-A76 (ARMv8.2): no pointer auth/SVE/MOPS to emulate, so TCG is faster, and `max`'s
            // FEAT_MOPS memset crashed the guest kernel while loading modules (QEMU 8.2 in CI).
            "-cpu", "cortex-a76",
            // split-wx: RW/RX mirror mapping, the only way to JIT with just a debugger attached (as UTM does).
            "-accel", "tcg,thread=multi,tb-size=256,split-wx=on",
            "-smp", "\(cores)",
            "-m", "1024",
            "-nodefaults", "-no-user-config", "-display", "none", "-monitor", "none",
            "-kernel", docs.appendingPathComponent("Image").path,
            "-initrd", docs.appendingPathComponent("initramfs.img").path,
            // earlycon: kernel output from the first instruction on; ttyAMA0 last = /dev/console, so systemd's status goes there too.
            "-append", "root=/dev/vda rw rootwait earlycon=pl011,0x9000000 console=hvc0 console=ttyAMA0 loglevel=6 systemd.show_status=1",
            "-chardev", "socket,id=ser,path=\(serial),server=on,wait=off",
            "-serial", "chardev:ser",
            "-device", "virtio-serial-pci",
            "-chardev", "socket,id=con,path=\(console),server=on,wait=off",
            "-device", "virtconsole,chardev=con",
            "-chardev", "socket,id=rsz,path=\(resize),server=on,wait=off",
            "-device", "virtserialport,chardev=rsz,name=dev.archprt.resize",
            "-drive", "if=none,id=disk,format=raw,cache=writeback,aio=threads,discard=unmap,file=" + docs.appendingPathComponent("arch.img").path,
            "-device", "virtio-blk-pci,drive=disk",
            "-netdev", "user,id=net",
            "-device", "virtio-net-pci,netdev=net,romfile=",
            "-device", "virtio-rng-pci",
        ]
    }

    // MARK: - Sockets

    private func connect(_ path: String) -> Int32 {
        for _ in 0..<600 {
            let fd = archprt_connect(path)
            if fd >= 0 { return fd }
            usleep(100_000)
        }
        return -1
    }

    private func pump(path: String) {
        let fd = connect(path)
        guard fd >= 0 else { return }
        console = fd
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            let chunk = Array(buf[0..<n])
            DispatchQueue.main.async {
                if self.state == .booting { self.bootOutput(chunk) } else { self.feed(chunk) }
            }
        }
    }

    private func feed(_ chunk: [UInt8]) {
        if let out = onOutput { out(chunk[...]) } else { pending += chunk }
    }

    /// While booting, hvc0 only waits for agetty's autologin line; the terminal starts right after it.
    /// (Boot messages come from the serial port, see serialLog.)
    private func bootOutput(_ chunk: [UInt8]) {
        let window = markerTail + chunk
        if let hit = window.firstRange(of: VM.loginMarker) {
            state = .running
            feed(Array(window[hit.upperBound...]))
            return
        }
        markerTail = Array(window.suffix(VM.loginMarker.count))
    }

    /// ttyAMA0: kernel + systemd boot output, live on the loading screen and saved to Documents/boot.log.
    private func serialLog(path: String) {
        let fd = connect(path)
        guard fd >= 0 else { return }
        let logURL = docs.appendingPathComponent("boot.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            let chunk = Data(buf[0..<n])
            try? log?.write(contentsOf: chunk)
            let text = String(decoding: chunk, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{7}]*\u{7}|\r", with: "", options: .regularExpression)
            DispatchQueue.main.async { self.bootLog = String((self.bootLog + text).suffix(12_000)) }
        }
        try? log?.close()
    }

    /// The guest's archprt-resize asks ("?") whenever it (re)starts; we answer with the terminal size.
    private func handshake(path: String) {
        let fd = connect(path)
        guard fd >= 0 else { return }
        resizer = fd
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            DispatchQueue.main.async { self.sendSize() }
        }
    }

    private func sendSize() {
        guard resizer >= 0 else { return }
        let line = Array("\(size.rows) \(size.cols)\n".utf8)
        _ = line.withUnsafeBytes { Darwin.write(resizer, $0.baseAddress, $0.count) }
    }
}
