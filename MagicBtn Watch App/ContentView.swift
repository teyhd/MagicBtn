import SwiftUI
import Combine
import AVFoundation
import os
import Network

// =====================
// MARK: - Endpoints
// =====================
private enum Endpoints {
    static let baseURL = URL(string: "https://rec.platoniks.ru")!
    static let pingPath = "ping"
    static let msgPath  = "msg"

    // NEW: chunk upload
    static let audioChunkPath  = "audio/chunk"
    static let audioFinishPath = "audio/finish"
}

// =====================
// MARK: - Logs (visible + autoscroll)
// =====================
struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
}

@MainActor
final class LogStore: ObservableObject {
    @Published var lines: [LogLine] = []
    private let logger = Logger(subsystem: "ru.platoniks.watchrec", category: "watch")

    func info(_ t: String)  { logger.info("\(t, privacy: .public)");  append("ℹ️ \(t)") }
    func warn(_ t: String)  { logger.warning("\(t, privacy: .public)"); append("⚠️ \(t)") }
    func error(_ t: String) { logger.error("\(t, privacy: .public)"); append("❌ \(t)") }

    private func append(_ t: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        lines.append(LogLine(text: "[\(ts)] \(t)"))
        if lines.count > 350 { lines.removeFirst(lines.count - 350) }
    }
}

// =====================
// MARK: - HTTP Client
// =====================
struct APIClient {
    func get(path: String, query: [URLQueryItem] = []) async throws -> (code: Int, body: String) {
        let url = Endpoints.baseURL.appendingPathComponent(path)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.allowsExpensiveNetworkAccess = true
        req.allowsConstrainedNetworkAccess = true
        req.networkServiceType = .responsiveData

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""
        return (code, body)
    }

    func postBinary(path: String, query: [URLQueryItem], body: Data, serviceType: URLRequest.NetworkServiceType = .avStreaming) async throws -> Int {
        let url = Endpoints.baseURL.appendingPathComponent(path)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = query

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.allowsExpensiveNetworkAccess = true
        req.allowsConstrainedNetworkAccess = true
        req.networkServiceType = serviceType
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")

        let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
        return (resp as? HTTPURLResponse)?.statusCode ?? -1
    }
}

// =====================
// MARK: - Upload queue (sequential, no overload)
// =====================
actor UploadQueue {
    private let api = APIClient()
    private let log: LogStore

    private var sid: String = ""
    private var seq: UInt32 = 0
    private var sr: Int = 16000
    private var fmt: String = "s16le"
    private var started = false

    init(log: LogStore) { self.log = log }

    func startNewSession(sampleRate: Int) {
        sid = UUID().uuidString.lowercased()
        seq = 0
        sr = sampleRate
        fmt = "s16le"
        started = true
        let sidPreview = String(sid.prefix(8))
        Task { @MainActor in log.info("Upload session sid=\(sidPreview)…") }
    }

    func uploadChunk(_ data: Data) async -> Bool {
        guard started else { return false }
        let mySeq = seq
        seq &+= 1

        do {
            let code = try await api.postBinary(
                path: Endpoints.audioChunkPath,
                query: [
                    URLQueryItem(name: "sid", value: sid),
                    URLQueryItem(name: "seq", value: String(mySeq)),
                    URLQueryItem(name: "sr",  value: String(sr)),
                    URLQueryItem(name: "fmt", value: fmt)
                ],
                body: data,
                serviceType: .avStreaming
            )
            if code >= 200 && code < 300 {
                return true
            } else {
                Task { @MainActor in log.warn("chunk seq=\(mySeq) => HTTP \(code)") }
                return false
            }
        } catch {
            Task { @MainActor in log.error("chunk seq=\(mySeq) upload failed: \(error.localizedDescription)") }
            return false
        }
    }

    func finish() async {
        guard started else { return }
        started = false
        do {
            let code = try await api.postBinary(
                path: Endpoints.audioFinishPath,
                query: [
                    URLQueryItem(name: "sid", value: sid),
                    URLQueryItem(name: "sr",  value: String(sr)),
                    URLQueryItem(name: "fmt", value: fmt)
                ],
                body: Data(),
                serviceType: .avStreaming
            )
            let sidPreview = String(sid.prefix(8))
            Task { @MainActor in log.info("finish => HTTP \(code) (sid=\(sidPreview)…)") }
        } catch {
            Task { @MainActor in log.error("finish failed: \(error.localizedDescription)") }
        }
    }
}

// =====================
// MARK: - Audio Chunk Streamer (no WebSocket)
// =====================
final class AudioChunkStreamer {
    enum State: Equatable { case idle, starting, streaming, stopping }

    private let log: LogStore
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?

    private let lock = NSLock()
    private var _state: State = .idle
    private func setState(_ s: State) { lock.withLock { _state = s } }
    var state: State { lock.withLock { _state } }

    private let uploader: UploadQueue
    private var buffer = Data()           // accumulated PCM
    private var flushTask: Task<Void, Never>?
    private let targetChunkBytes = 32000   // ~1 sec at 16kHz mono s16 (16000*2)

    // UI hint
    var onConnectivityHint: ((Bool) -> Void)?

    init(log: LogStore) {
        self.log = log
        self.uploader = UploadQueue(log: log)
    }

    @MainActor
    func start() async {
        guard state == .idle else { return }
        setState(.starting)

        let micOK = await requestMicPermission()
        guard micOK else {
            log.error("Microphone permission denied")
            setState(.idle)
            return
        }

        do {
            try configureAudioSessionForWatch()
            try startEngineAndTap()
            await uploader.startNewSession(sampleRate: 16000)

            // periodic flush (so even small buffers go out)
            flushTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                    await self.flushIfNeeded(force: false)
                }
            }

            setState(.streaming)
            onConnectivityHint?(true)
            log.info("🎙️ Streaming started (HTTPS chunks)")
        } catch {
            onConnectivityHint?(false)
            log.error("Start failed: \(error.localizedDescription)")
            await stop()
        }
    }

    @MainActor
    func stop() async {
        guard state != .idle else { return }
        setState(.stopping)
        log.info("Stopping...")

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        flushTask?.cancel()
        flushTask = nil

        // final flush + finish
        await flushIfNeeded(force: true)
        await uploader.finish()

        setState(.idle)
        log.info("🛑 Streaming stopped")
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    private func configureAudioSessionForWatch() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
        try s.setActive(true)
        Task { @MainActor in self.log.info("AudioSession active") }
    }

    private func startEngineAndTap() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)

        let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                sampleRate: 16000,
                                channels: 1,
                                interleaved: false)!

        guard let conv = AVAudioConverter(from: inFormat, to: out) else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter init failed"])
        }
        self.outFormat = out
        self.converter = conv

        engine.prepare()
        try engine.start()

        Task { @MainActor in
            self.log.info("Engine started (inSR=\(Int(inFormat.sampleRate)) ch=\(inFormat.channelCount) -> 16k mono s16le)")
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.convertAndAppend(buf)
        }
    }

    private func convertAndAppend(_ bufferIn: AVAudioPCMBuffer) {
        guard state == .streaming || state == .starting,
              let conv = converter,
              let out = outFormat
        else { return }

        let ratio = out.sampleRate / bufferIn.format.sampleRate
        let outCap = AVAudioFrameCount(Double(bufferIn.frameLength) * ratio) + 32
        guard let bufferOut = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: outCap) else { return }

        var err: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, st in
            st.pointee = .haveData
            return bufferIn
        }
        conv.convert(to: bufferOut, error: &err, withInputFrom: inputBlock)
        if let err {
            Task { @MainActor in self.log.error("Convert error: \(err.localizedDescription)") }
            return
        }

        let frames = Int(bufferOut.frameLength)
        guard frames > 0, let ch0 = bufferOut.int16ChannelData?[0] else { return }

        let bytes = frames * MemoryLayout<Int16>.size
        // append PCM bytes
        buffer.withUnsafeMutableBytes { _ in } // keep Data mutable
        let pcm = Data(bytes: ch0, count: bytes)

        lock.withLock {
            self.buffer.append(pcm)
        }

        // fast path flush if >= 1s
        Task.detached { [weak self] in
            await self?.flushIfNeeded(force: false)
        }
    }

    private func takeChunk(_ maxBytes: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.count >= maxBytes else { return nil }
        let chunk = buffer.prefix(maxBytes)
        buffer.removeFirst(maxBytes)
        return Data(chunk)
    }

    private func takeAll() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let all = buffer
        buffer.removeAll(keepingCapacity: true)
        return all
    }

    func flushIfNeeded(force: Bool) async {
        guard state != .idle else { return }

        while true {
            let data: Data?
            if force {
                data = takeAll()
            } else {
                data = takeChunk(targetChunkBytes)
            }

            guard let chunk = data, !chunk.isEmpty else { break }

            let ok = await uploader.uploadChunk(chunk)
            onConnectivityHint?(ok)
        }
    }
}

// =====================
// MARK: - App Model
// =====================
@MainActor
final class AppModel: ObservableObject {
    @Published var pingStatus: String = "—"
    @Published var netStatus: String = "Checking…"
    @Published var isStreaming: Bool = false

    let log = LogStore()
    private let api = APIClient()

    private lazy var streamer: AudioChunkStreamer = {
        let s = AudioChunkStreamer(log: log)
        s.onConnectivityHint = { [weak self] ok in
            Task { @MainActor in self?.netStatus = ok ? "Online" : "Offline" }
        }
        return s
    }()

    private var monitor: NWPathMonitor?
    private let q = DispatchQueue(label: "net.monitor")

    func onAppear() {
        log.info("App launched")
        startNetworkMonitor()
        Task { await ping() }
    }

    func onDisappear() {
        monitor?.cancel()
        monitor = nil
    }

    func ping() async {
        do {
            let res = try await api.get(path: Endpoints.pingPath)
            pingStatus = "HTTP \(res.code)"
            netStatus = "Online"
            log.info("PING => \(res.code) \(res.body)")
        } catch {
            pingStatus = "FAIL"
            netStatus = "Offline"
            log.error("PING failed: \(error.localizedDescription)")
        }
    }

    func test() async {
        do {
            let res = try await api.get(path: Endpoints.msgPath,
                                        query: [URLQueryItem(name: "msg", value: "hii")])
            netStatus = "Online"
            log.info("TEST => \(res.code) \(res.body)")
        } catch {
            netStatus = "Offline"
            log.error("TEST failed: \(error.localizedDescription)")
        }
    }

    func toggleStreaming() {
        Task {
            if isStreaming {
                await streamer.stop()
                isStreaming = false
            } else {
                await streamer.start()
                isStreaming = (streamer.state == .streaming)
            }
        }
    }

    private func startNetworkMonitor() {
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied {
                    self.netStatus = path.isExpensive ? "Online (exp)" : "Online"
                } else {
                    self.netStatus = "Offline"
                }
            }
        }
        m.start(queue: q)
    }
}

// =====================
// MARK: - UI (logs visible, higher, autoscroll)
// =====================
struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Net: \(model.netStatus)")
                Text("Ping: \(model.pingStatus)").monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.footnote)
            .padding(.top, 10)

            Divider()
            
            HStack(spacing: 4) {
                Button("Стоп") { Task { await model.ping() } }
                    .tint(.red)
                Button("Повтор") { Task { await model.test() } }
            }.font(.system(size: 12))
                .controlSize(.mini)
                .buttonStyle(.borderedProminent)
                .padding(.vertical, 2)

            Button(model.isStreaming ? "Стоп" : "Запись") {
                model.toggleStreaming()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isStreaming ? .red : .green)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.log.lines.suffix(70)) { line in
                            Text(line.text)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 80) // <<< лог реально видно
                .onChange(of: model.log.lines.count) { _ in
                    if let last = model.log.lines.last {
                        withAnimation(.linear(duration: 0.12)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(5)
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }
}

// =====================
// MARK: - Helpers
// =====================
private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
