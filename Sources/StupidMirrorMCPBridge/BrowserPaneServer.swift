import Darwin
import Foundation
import StupidMirrorBridgeCore

/// Serves `BrowserPaneLanding` on loopback until Claude stops the preview.
enum BrowserPaneServer {
    static func run(port: Int) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { fail("socket failed: \(String(cString: strerror(errno)))") }
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { fail("Port \(port) is unavailable: \(String(cString: strerror(errno)))") }
        guard listen(listener, 16) == 0 else { fail("listen failed: \(String(cString: strerror(errno)))") }
        FileHandle.standardError.write(Data("StupidMirror Browser pane page on http://localhost:\(port)\n".utf8))

        let queue = DispatchQueue(label: "stupidmirror.browser-pane", attributes: .concurrent)
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                fail("accept failed: \(String(cString: strerror(errno)))")
            }
            queue.async { serve(client, port: port) }
        }
    }

    private static func serve(_ client: Int32, port: Int) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while !BrowserPaneLanding.headIsComplete(request), request.count < BrowserPaneLanding.maximumRequestSize {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            request.append(chunk, count: count)
        }
        let message = BrowserPaneLanding.response(forRequest: request, port: port).serialized
        message.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("StupidMirror: \(message)\n".utf8))
        exit(1)
    }
}
