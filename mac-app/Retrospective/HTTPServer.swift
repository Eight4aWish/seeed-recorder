// HTTP/Bonjour trigger path. Implements the v2.0 RECORDER_PROTOCOL
// (see eurorack_modules/docs/RECORDER_PROTOCOL.md):
//
//   GET  /healthz   liveness + capture-readiness probe
//   POST /capture   trigger; awaits extraction, returns file list + duration
//
// Bound to all interfaces — the protocol assumes the LAN is trusted (no auth
// in v2.0). Bonjour advertises `_recorder._tcp.local.` on the same port with
// TXT records `version=2.0`, `app=seeed-recorder`, `link_peer=true|false`.
//
// HTTP parsing is hand-rolled and minimal: only the request line is parsed
// (method + path). Bodies are empty for both supported endpoints.

import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "HTTPServer")

@MainActor
final class HTTPServer: ObservableObject {
    static let defaultPort: UInt16 = 8765
    static let bonjourType = "_recorder._tcp."
    static let bonjourName = "seeed-recorder"
    static let protocolVersion = "2.0"

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16 = HTTPServer.defaultPort
    @Published private(set) var lastError: String?

    private let coordinator: CaptureCoordinator
    private let engine: AudioCaptureEngine

    private var listener: NWListener?
    private var bonjour: NetService?
    private let queue = DispatchQueue(label: "com.n8synth.retrospective.http",
                                      qos: .userInitiated)

    init(coordinator: CaptureCoordinator, engine: AudioCaptureEngine, autoStart: Bool = true) {
        self.coordinator = coordinator
        self.engine = engine
        if autoStart { start() }
    }

    func start(port requestedPort: UInt16 = HTTPServer.defaultPort) {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else {
            lastError = "Invalid port \(requestedPort)"
            return
        }
        do {
            let params = NWParameters.tcp
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    Task { @MainActor [weak self] in
                        self?.lastError = "Listener failed: \(err.localizedDescription)"
                    }
                }
            }
            l.start(queue: queue)
            self.listener = l
            self.port = requestedPort
            startBonjour(on: requestedPort)
            isRunning = true
            log.info("HTTP listening on TCP/\(requestedPort, privacy: .public); Bonjour advertised")
        } catch {
            lastError = "Could not bind TCP/\(requestedPort): \(error.localizedDescription)"
            log.error("Listener init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        bonjour?.stop()
        bonjour = nil
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Bonjour

    private func startBonjour(on port: UInt16) {
        let svc = NetService(domain: "", type: Self.bonjourType,
                             name: Self.bonjourName, port: Int32(port))
        svc.includesPeerToPeer = false
        svc.publish()
        bonjour = svc
        refreshBonjourTXT()
    }

    /// Rewrites the TXT record to reflect current Link state. Called whenever
    /// link_peer flips. Phase 4 should call this on Link membership changes.
    func refreshBonjourTXT() {
        guard let svc = bonjour else { return }
        let txt = NetService.data(fromTXTRecord: [
            "version":   Data(Self.protocolVersion.utf8),
            "app":       Data(Self.bonjourName.utf8),
            "link_peer": Data("false".utf8),     // Phase 4: dynamic
        ])
        svc.setTXTRecord(txt)
    }

    // MARK: - Connection lifecycle

    private nonisolated func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
            if case .cancelled = state { /* done */ }
        }
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private nonisolated func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            // Wait until we've seen the request line + headers terminator.
            if let endRange = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: 0..<endRange.lowerBound)
                self.dispatch(headerData: headerData, conn: conn)
                return
            }
            if isComplete || error != nil {
                self.send(status: 400, statusText: "Bad Request",
                          body: errorJSON(reason: "malformed_request", detail: "Incomplete HTTP request"),
                          conn: conn)
                return
            }
            self.receiveRequest(conn, buffer: buf)
        }
    }

    private nonisolated func dispatch(headerData: Data, conn: NWConnection) {
        guard let line = String(data: headerData, encoding: .ascii)?.components(separatedBy: "\r\n").first else {
            self.send(status: 400, statusText: "Bad Request",
                      body: errorJSON(reason: "malformed_request", detail: "Invalid request line"),
                      conn: conn)
            return
        }
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else {
            self.send(status: 400, statusText: "Bad Request",
                      body: errorJSON(reason: "malformed_request", detail: "Invalid request line"),
                      conn: conn)
            return
        }
        let method = parts[0]
        let path = parts[1]
        log.debug("\(method, privacy: .public) \(path, privacy: .public)")

        Task { @MainActor [weak self] in
            guard let self else { conn.cancel(); return }
            switch (method, path) {
            case ("GET", "/healthz"):
                let (status, body) = self.handleHealth()
                self.send(status: status, statusText: status == 200 ? "OK" : "Service Unavailable",
                          body: body, conn: conn)
            case ("POST", "/capture"):
                let (status, body) = await self.handleCapture()
                self.send(status: status, statusText: status == 200 ? "OK" : "Service Unavailable",
                          body: body, conn: conn)
            default:
                self.send(status: 404, statusText: "Not Found",
                          body: errorJSON(reason: "not_found", detail: "\(method) \(path)"),
                          conn: conn)
            }
        }
    }

    private nonisolated func send(status: Int, statusText: String, body: Data, conn: NWConnection) {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Endpoint handlers

    private func handleHealth() -> (Int, Data) {
        if engine.isCapturing {
            let resp = HealthOK(
                ok: true,
                version: Self.protocolVersion,
                app: Self.bonjourName,
                buffer_seconds: Int(engine.lookbackSeconds),
                audio_source: engine.selectedDevice?.name,
                channels_active: engine.channelCount,
                link_peer: false,           // Phase 4
                link_tempo: nil)            // Phase 4
            return (200, encode(resp))
        } else {
            return (503, errorJSON(reason: "no_audio_source",
                                   detail: "No input device configured."))
        }
    }

    private func handleCapture() async -> (Int, Data) {
        do {
            let result = try await coordinator.performCapture(source: "http")
            let resp = CaptureOK(
                ok: true,
                files: result.writtenFiles.map { $0.path },
                duration_seconds: Int(engine.lookbackSeconds),
                bpm: nil,                    // Phase 4
                link_playing: nil)           // Phase 4
            return (200, encode(resp))
        } catch CaptureError.alreadyInFlight {
            return (503, errorJSON(reason: "capture_in_flight",
                                   detail: "A capture is already in progress."))
        } catch CaptureError.noAudioSource {
            return (503, errorJSON(reason: "no_audio_source",
                                   detail: "No input device configured."))
        } catch CaptureError.extractionFailed(let msg) {
            return (503, errorJSON(reason: "extraction_failed", detail: msg))
        } catch {
            return (503, errorJSON(reason: "extraction_failed", detail: error.localizedDescription))
        }
    }
}

// MARK: - JSON shapes

private struct HealthOK: Encodable {
    let ok: Bool
    let version: String
    let app: String
    let buffer_seconds: Int
    let audio_source: String?
    let channels_active: Int
    let link_peer: Bool
    let link_tempo: Double?

    enum CodingKeys: String, CodingKey {
        case ok, version, app, buffer_seconds, audio_source, channels_active, link_peer, link_tempo
    }

    /// Omit nil optional fields (per protocol: link_tempo absent when no Link peer).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        try c.encode(version, forKey: .version)
        try c.encode(app, forKey: .app)
        try c.encode(buffer_seconds, forKey: .buffer_seconds)
        try c.encodeIfPresent(audio_source, forKey: .audio_source)
        try c.encode(channels_active, forKey: .channels_active)
        try c.encode(link_peer, forKey: .link_peer)
        try c.encodeIfPresent(link_tempo, forKey: .link_tempo)
    }
}

private struct CaptureOK: Encodable {
    let ok: Bool
    let files: [String]
    let duration_seconds: Int
    let bpm: Double?
    let link_playing: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, files, duration_seconds, bpm, link_playing
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        try c.encode(files, forKey: .files)
        try c.encode(duration_seconds, forKey: .duration_seconds)
        try c.encodeIfPresent(bpm, forKey: .bpm)
        try c.encodeIfPresent(link_playing, forKey: .link_playing)
    }
}

private struct ErrorBody: Encodable {
    let ok: Bool   // always false
    let reason: String
    let detail: String
}

// MARK: - JSON helpers

private func encode<T: Encodable>(_ value: T) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    return (try? enc.encode(value)) ?? Data()
}

private func errorJSON(reason: String, detail: String) -> Data {
    encode(ErrorBody(ok: false, reason: reason, detail: detail))
}
