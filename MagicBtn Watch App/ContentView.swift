//
//  ContentView.swift
//  MagicBtn Watch App
//
//  Created by Владислав on 25.12.2025.
//

import SwiftUI
import AVFoundation

// =================== НАСТРОЙКИ ===================
private let STREAM_URL = URL(string: "https://rec.platoniks.ru/stream")! // <-- замени
private let SAMPLE_RATE: Double = 16000
private let CHANNELS: AVAudioChannelCount = 1
private let CHUNK_FRAMES: AVAudioFrameCount = 1024
private let HTTP_TIMEOUT: TimeInterval = 60

// Переподключение
private let RECONNECT_BASE_DELAY: TimeInterval = 0.5
private let RECONNECT_MAX_DELAY: TimeInterval  = 8.0
private let RECONNECT_MAX_TRIES = 0 // 0 = бесконечно
// =================================================

struct ContentView: View {
    @StateObject private var vm = WatchPCMStreamer()

    var body: some View {
        VStack(spacing: 10) {
            Button(action: { vm.toggle() }) {
                Text(vm.isStreaming ? "Стоп" : "Записать")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)

            if let status = vm.status {
                Text(status)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .onAppear { vm.prepare() }
    }
}

final class WatchPCMStreamer: NSObject, ObservableObject {
    @Published var isStreaming = false
    @Published var status: String?

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()

    private var streamTask: URLSessionStreamTask?
    private var output: OutputStream?
    private var outputOpened = false

    // reconnect state
    private var wantStreaming = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var connecting = false

    // audio convert
    private var converter: AVAudioConverter?
    private var desiredFormat: AVAudioFormat?
    private var inputFormat: AVAudioFormat?

    func prepare() {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            status = "AudioSession: \(error.localizedDescription)"
        }
    }

    func toggle() {
        isStreaming ? stop() : start()
    }

    private func start() {
        status = "Запрос микрофона…"
        session.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.status = "Нет доступа к микрофону"; return }
                self.startStreamingFlow()
            }
        }
    }

    private func startStreamingFlow() {
        wantStreaming = true
        reconnectAttempt = 0
        isStreaming = true

        setupAudioIfNeeded()
        startEngineIfNeeded()
        ensureConnected()
    }

    private func setupAudioIfNeeded() {
        if inputFormat != nil { return }

        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        inputFormat = inFmt

        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: SAMPLE_RATE,
                                         channels: CHANNELS,
                                         interleaved: true) else {
            status = "Не создался формат аудио"
            stop()
            return
        }
        desiredFormat = outFmt

        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            status = "Не создался конвертер"
            stop()
            return
        }
        converter = conv

        // tap ставим один раз, дальше просто (не)шлём
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: CHUNK_FRAMES, format: inFmt) { [weak self] buffer, _ in
            guard let self, self.wantStreaming else { return }
            guard self.outputOpened, let os = self.output,
                  let conv = self.converter, let outFmt = self.desiredFormat,
                  let inFmt = self.inputFormat else { return } // если сети нет — дропаем чанки

            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (SAMPLE_RATE / inFmt.sampleRate) + 32)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else { return }

            var err: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            conv.convert(to: outBuffer, error: &err, withInputFrom: inputBlock)

            if let err = err {
                DispatchQueue.main.async { self.status = "Конвертация: \(err.localizedDescription)" }
                return
            }

            guard let raw = outBuffer.int16ChannelData else { return }
            let frames = Int(outBuffer.frameLength)
            let byteCount = frames * Int(CHANNELS) * MemoryLayout<Int16>.size
            let ptr = UnsafeRawPointer(raw.pointee)
            let data = Data(bytes: ptr, count: byteCount)

            if !self.writeToOutputStream(os, data: data) {
                self.networkBroke()
            }
        }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            status = "Engine: \(error.localizedDescription)"
            stop()
        }
    }

    // MARK: - Connection / Reconnect

    private func ensureConnected() {
        guard wantStreaming else { return }
        guard !connecting else { return }
        guard outputOpened == false else { return } // уже подключены

        connecting = true
        status = "Подключение…"

        var req = URLRequest(url: STREAM_URL)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = HTTP_TIMEOUT

        let task = URLSession(configuration: .default).streamTask(with: req)
        task.resume()
        streamTask = task

        var capturedOut: OutputStream?
        task.captureStreams { _, outStream in
            capturedOut = outStream
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            defer { self.connecting = false }

            guard self.wantStreaming else { self.closeNetwork(); return }
            guard let os = capturedOut else {
                self.scheduleReconnect(reason: "Нет потока")
                return
            }

            self.output = os
            self.openOutputIfNeeded()
            DispatchQueue.main.async { self.status = "Стрим…" }
            self.reconnectAttempt = 0
        }
    }

    private func networkBroke() {
        closeNetwork()
        scheduleReconnect(reason: "Обрыв сети")
    }

    private func scheduleReconnect(reason: String) {
        guard wantStreaming else { return }

        reconnectWorkItem?.cancel()
        reconnectAttempt += 1

        if RECONNECT_MAX_TRIES > 0 && reconnectAttempt > RECONNECT_MAX_TRIES {
            DispatchQueue.main.async { self.status = "\(reason). Стоп (лимит попыток)" }
            stop()
            return
        }

        let delay = min(RECONNECT_MAX_DELAY, RECONNECT_BASE_DELAY * pow(2.0, Double(max(0, reconnectAttempt - 1))))
        DispatchQueue.main.async { self.status = "\(reason). Переподключение через \(String(format: "%.1f", delay))с…" }

        let item = DispatchWorkItem { [weak self] in
            self?.ensureConnected()
        }
        reconnectWorkItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func closeNetwork() {
        output?.close()
        output = nil
        outputOpened = false

        streamTask?.cancel()
        streamTask = nil
    }

    private func openOutputIfNeeded() {
        guard let os = output, !outputOpened else { return }
        os.schedule(in: .current, forMode: .default)
        os.open()
        outputOpened = true
    }

    // returns false on error
    private func writeToOutputStream(_ os: OutputStream, data: Data) -> Bool {
        var ok = true
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { ok = false; return }
            var sent = 0
            while sent < data.count && wantStreaming {
                let n = os.write(base.advanced(by: sent), maxLength: data.count - sent)
                if n <= 0 { ok = false; break }
                sent += n
            }
        }
        return ok
    }

    // MARK: - Stop

    func stop() {
        wantStreaming = false
        isStreaming = false

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        closeNetwork()
        connecting = false
        reconnectAttempt = 0

        if status == nil || status == "Стрим…" { status = "Остановлено" }
    }
}
