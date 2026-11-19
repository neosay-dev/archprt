import SwiftUI

@main
struct ArchPrtApp: App {
    @StateObject private var vm = VM.shared

    var body: some Scene {
        WindowGroup {
            Root()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
                .onAppear { vm.launch() }
        }
    }
}

struct Root: View {
    @EnvironmentObject var vm: VM

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch vm.state {
            case .needsDownload(let error):
                Setup(
                    title: "Arch Linux",
                    text: error.map { "Не получилось: \($0)\n\nПопробуй ещё раз: уже скачанные файлы заново не качаются." }
                        ?? "Лёгкий Arch Linux ARM: 230 МБ скачать, 1,6 ГБ на диске. Скачай, пока приложение открыто.",
                    button: "Скачать"
                ) { vm.download() }
            case .downloading(let step, let progress):
                VStack(alignment: .leading, spacing: 12) {
                    Text("Arch Linux").font(.title2.weight(.semibold))
                    ProgressView(value: progress).tint(.white)
                    Text(step).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(28)
                .frame(maxWidth: 520)
            case .ready:
                Setup(title: "Arch Linux готов", text: "Для запуска нужен JIT из StikDebug.", button: "Запустить") { vm.start() }
            case .noJIT:
                Message(
                    title: "Нужен JIT",
                    text: "Arch работает в виртуальной машине, а ей нужен JIT. Открой StikDebug, выбери ArchPrt и нажми «Enable JIT» — приложение запустится уже с ним.",
                    action: ("Открыть StikDebug", URL(string: "stikjit://enable-jit?bundle-id=dev.neosay.archprt")!)
                )
            case .stopped(let reason):
                Message(title: "Arch остановлен", text: reason + "\n\nЧтобы запустить снова, закрой ArchPrt из переключателя приложений и включи JIT ещё раз.", action: nil)
            case .booting, .running:
                TerminalScreen()
                    .ignoresSafeArea(.container, edges: .bottom)
                if vm.state == .booting {
                    Booting().transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: vm.state)
    }
}

private struct Booting: View {
    @EnvironmentObject var vm: VM

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("ArchPrt").font(.system(size: 28, weight: .semibold))
                Spacer()
                TimelineView(.periodic(from: vm.bootStarted, by: 1)) { ctx in
                    let t = Int(ctx.date.timeIntervalSince(vm.bootStarted))
                    Text(String(format: "%d:%02d", t / 60, t % 60))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            // Live kernel/systemd output from the guest console, newest at the bottom.
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    Text(vm.bootLog.isEmpty ? "Запуск ядра…" : vm.bootLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log")
                }
                .onChange(of: vm.bootLog) { _ in proxy.scrollTo("log", anchor: .bottom) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

private struct Setup: View {
    let title: String
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(text).font(.body).foregroundStyle(.secondary)
            Button(action: action) {
                Text(button)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .foregroundStyle(.black)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 12)
        }
        .padding(28)
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct Message: View {
    let title: String
    let text: String
    let action: (String, URL)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(text).font(.body).foregroundStyle(.secondary)
            if let action {
                Link(action.0, destination: action.1)
                    .font(.body.weight(.semibold))
                    .padding(.top, 8)
            }
        }
        .padding(28)
        .frame(maxWidth: 520, alignment: .leading)
    }
}
