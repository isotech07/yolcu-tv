import CryptoKit
import Foundation
import Network

/// Yayın uzantısının içinde çalışan küçük HTTP + WebSocket sunucusu.
/// iOS ana uygulamayı arka planda askıya aldığı için görüntüyü uzantı kendisi sunar.
///
///   GET /               → ekran.html (Android'deki sayfanın aynısı)
///   GET /static/jmuxer.min.js
///   GET /ws-ekran       → WebSocket: ikili kareler + metin kontrol mesajları
///
/// Uzantının bellek sınırı düşük (~50 MB). Yavaş bağlanan ekranlar için bekleyen
/// veri sınırı var: aşılırsa o ekran bir sonraki anahtar kareye kadar atlanır.
final class MirrorServer {
    var onClientNeedsKeyFrame: (() -> Void)?

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "yolcutv.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var rotation = 0
    private static let maxPendingBytes = 1_500_000

    private final class Client {
        let connection: NWConnection
        var ready = false
        var pendingBytes = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8090
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let l = try NWListener(using: parameters, on: port)
            l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            l.stateUpdateHandler = { state in
                if case .failed(let error) = state { NSLog("YolcuTV sunucu hatası: \(error)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("YolcuTV sunucu başlatılamadı: \(error)")
        }
    }

    func stop() {
        queue.sync {
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    /// Kodlayıcıdan gelen paket (herhangi bir iş parçacığından çağrılabilir).
    func broadcast(_ packet: Data) {
        queue.async {
            guard !self.clients.isEmpty, let flag = packet.first else { return }
            let isKey = flag == 1
            let framed = Self.frame(opcode: 0x2, payload: packet)
            for client in self.clients.values {
                if !client.ready {
                    // Çözücü anahtar kareden başlamalı.
                    guard isKey, client.pendingBytes < Self.maxPendingBytes else { continue }
                    client.ready = true
                } else if client.pendingBytes > Self.maxPendingBytes {
                    // Bu ekran geride kaldı: kareleri atla, sonraki anahtar kareden devam et.
                    client.ready = false
                    self.onClientNeedsKeyFrame?()
                    continue
                }
                self.send(framed, to: client)
            }
        }
    }

    /// Telefonun yönü değişince tarayıcıya bildirir (döndürmeyi tarayıcı yapar).
    func setRotation(_ degrees: Int) {
        queue.async {
            guard degrees != self.rotation else { return }
            self.rotation = degrees
            let text = "{\"type\":\"rotate\",\"deg\":\(degrees)}"
            for client in self.clients.values { self.sendText(text, to: client) }
        }
    }

    // MARK: - Bağlantılar

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                self.route(connection, head: head)
            } else if error != nil || done || buffer.count > 32_768 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(connection, status: "405 Method Not Allowed", type: "text/plain", body: Data())
            return
        }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if path == "/ws-ekran",
           headers["upgrade"]?.lowercased() == "websocket",
           let key = headers["sec-websocket-key"] {
            upgrade(connection, key: key)
            return
        }

        switch path {
        case "/", "/ekran":
            serveResource(connection, name: "ekran", ext: "html", type: "text/html; charset=utf-8")
        case "/static/jmuxer.min.js":
            serveResource(connection, name: "jmuxer.min", ext: "js", type: "application/javascript; charset=utf-8")
        case "/api/state":
            respond(connection, status: "200 OK", type: "application/json", body: Data("{\"mirror\":true}".utf8))
        default:
            respond(connection, status: "404 Not Found", type: "text/plain; charset=utf-8", body: Data("Bulunamadı".utf8))
        }
    }

    private func serveResource(_ connection: NWConnection, name: String, ext: String, type: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }
        respond(connection, status: "200 OK", type: type, body: data)
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - WebSocket

    private func upgrade(_ connection: NWConnection, key: String) {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })

        let client = Client(connection)
        let id = ObjectIdentifier(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.clients.removeValue(forKey: id) // bağlantı kuyruğunda çalışır
            default:
                break
            }
        }
        sendText("{\"type\":\"on\"}", to: client)
        if rotation != 0 { sendText("{\"type\":\"rotate\",\"deg\":\(rotation)}", to: client) }
        onClientNeedsKeyFrame?()
        readFrames(connection, id: id)
    }

    /// Tarayıcıdan gelenleri yalnızca kapanışı fark etmek için okuruz.
    private func readFrames(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self = self else { return }
            let closeFrame = (data?.first).map { $0 & 0x0F == 0x8 } ?? false
            if done || error != nil || closeFrame {
                self.clients.removeValue(forKey: id)
                connection.cancel()
                return
            }
            self.readFrames(connection, id: id)
        }
    }

    private func sendText(_ text: String, to client: Client) {
        send(Self.frame(opcode: 0x1, payload: Data(text.utf8)), to: client)
    }

    private func send(_ framed: Data, to client: Client) {
        let size = framed.count
        client.pendingBytes += size
        client.connection.send(content: framed, completion: .contentProcessed { [weak client] _ in
            client?.pendingBytes -= size // bağlantı kuyruğunda (queue) çağrılır
        })
    }

    /// Sunucudan istemciye giden çerçeveler maskelenmez (RFC 6455).
    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var f = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            f.append(UInt8(n))
        } else if n <= 0xFFFF {
            f.append(126)
            f.append(UInt8((n >> 8) & 0xFF))
            f.append(UInt8(n & 0xFF))
        } else {
            f.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                f.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF))
            }
        }
        f.append(payload)
        return f
    }
}
