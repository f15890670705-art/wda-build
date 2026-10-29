import SwiftUI
import Foundation
import Network
import Darwin

enum BuildInfo {
    static let version = "2.0"
    static let build = "21"
    static let tag = "v2.0-b23"
}

/// 分步加载：启动只开 socket，其余全部手动触发，崩溃点一目了然。
final class WDAHost {
    static let shared = WDAHost()
    private(set) var log: [String] = []
    private var loaded: [String: UnsafeMutableRawPointer] = [:]
    var serverStarted = false
    var frameworksLoaded = false

    func append(_ s: String) {
        log.append(s)
        print("[WDHost] \(s)")
    }

    func clear() { log.removeAll() }

    private var fwDir: String { Bundle.main.bundlePath + "/Frameworks" }

    var loadedCount: Int { loaded.count }

    /// 第 1 步：只加载 AXRuntime（最轻量，验证 dlopen 本身没问题）
    func loadAXOnly() {
        let p = fwDir + "/AXRuntime.framework/AXRuntime"
        if dlopen(p, RTLD_NOW) != nil {
            append("✅[1] AXRuntime（内嵌）")
            return
        }
        // 内嵌没有就用系统的
        if dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW) != nil {
            append("✅[1] AXRuntime（系统）")
        } else {
            append("❌[1] AXRuntime 加载失败")
        }
    }

    /// 第 2 步：加载 XCTest 全套 + WebDriverAgentLib
    func loadXCTest() {
        setenv("DYLD_FRAMEWORK_PATH", fwDir, 1)
        let order = ["Testing", "XCTestCore", "XCTAutomationSupport", "XCTest",
                     "XCTestSupport", "XCUIAutomation", "XCUnit", "WebDriverAgentLib"]
        for name in order {
            let path = "\(fwDir)/\(name).framework/\(name)"
            dlerror()
            if let h = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                loaded[name] = h
                append("✅[2] \(name)")
            } else if let e = dlerror() {
                append("❌[2] \(name): \(String(cString: e).prefix(120))")
            } else {
                append("❌[2] \(name)")
            }
        }
        frameworksLoaded = objc_getClass("FBWebServer") != nil
        append(frameworksLoaded ? "✅[2] FBWebServer 类已注册" : "❌[2] FBWebServer 类缺失")
    }

    /// 第 3 步：探测 XCTRunnerDaemonSession（捕获异常原因）
    func probeSession() {
        append("--- 探测 XCTRunnerDaemonSession ---")
        if let e = AXProbeDaemonSession() {
            append("⚠️[3] 异常:")
            append(String(e.prefix(600)))
        } else {
            append("✅[3] sharedSession 成功")
        }
    }

    /// 第 4 步：启动 WDA HTTP server（常驻线程版，保住 XPC 连接）
    func startServer() {
        loadAll()
        setenv("USE_PORT", "8100", 1)
        setenv("MJPEG_SERVER_PORT", "9100", 1)
        AXStartWDAServerThread(nil)
        append("--- 常驻线程已启动（3 秒后 8100 应就绪）---")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            append("尝试连接验证: curl http://手机IP:8100/status")
        }
    }

    private func legacyStartServer() {
        append("--- 4a 测试本机 socket ---")
        for sockPath in ["/var/run/usbmuxd", "/var/run/lockdown.sock"] {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { append("❌ socket() 失败 errno=\(errno)"); continue }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(sockPath.utf8CString)
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                let cnt = min(pathBytes.count, dest.count - 1)
                dest.baseAddress!.copyMemory(from: Array(pathBytes.prefix(cnt)), byteCount: cnt)
            }
            let r = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if r == 0 {
                append("✅[4] connect \(sockPath) 成功!!")
                close(fd)
            } else {
                append("❌[4] connect \(sockPath) errno=\(errno) (\(String(cString: strerror(errno))))")
                close(fd)
            }
        }
        append("--- 4b 启动 FBWebServer ---")
        if let err = AXStartWDAServer() {
            append("❌[4] 异常:")
            append(String(err.prefix(600)))
            return
        }
        serverStarted = true
        append("✅[4] startHTTPServer 已调用")
    }

    func probe() -> [String: Any] {
        var out: [String: Any] = ["tag": BuildInfo.tag, "log": log,
                                  "loaded": loadedCount, "server": serverStarted]
        var cls: [String: Bool] = [:]
        for c in ["FBWebServer", "FBApplication", "FBXCTestDaemonsProxy", "XCUIDevice", "XCTRunnerDaemonSession"] {
            cls[c] = objc_getClass(c) != nil
        }
        out["classes"] = cls
        return out
    }
}

/// TCP 控制 10010
final class ControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ax.ctl")
    private var buffer = Data()

    func start(port: UInt16 = 10010) {
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: .tcp, on: p) else { return }
        listener = l
        l.newConnectionHandler = { c in
            c.start(queue: self.queue)
            self.handle(c)
        }
        l.start(queue: queue)
    }

    private func handle(_ c: NWConnection) {
        func rec() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, _ in
                if let d = d, !d.isEmpty { self.process(d, c) }
                if !done { rec() } else { c.cancel() }
            }
        }
        rec()
    }

    private func process(_ data: Data, _ c: NWConnection) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let ld = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: ld, encoding: .utf8), !line.isEmpty else { continue }
            var resp = "{\"ok\":false}"
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let cmd = obj["cmd"] as? String {
                switch cmd {
                case "ping": resp = "{\"ok\":true,\"tag\":\"\(BuildInfo.tag)\"}"
                case "probe":
                    resp = (try? String(data: JSONSerialization.data(withJSONObject: WDAHost.shared.probe()), encoding: .utf8)) ?? "{}"
                case "load": WDAHost.shared.loadXCTest(); resp = "{\"ok\":true}"
                case "server": WDAHost.shared.startServer(); resp = "{\"ok\":true}"
                default: resp = "{\"ok\":false,\"error\":\"unknown\"}"
                }
            }
            c.send(content: (resp + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }
}

@main
struct AXTouchApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var log = "就绪"

    var body: some View {
        VStack(spacing: 8) {
            Text("AXTouch \(BuildInfo.tag)").font(.title2).bold()
            Text("TCP 0.0.0.0:10010  |  \(WDAHost.shared.loadedCount) 个框架")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Button("1 AX") { WDAHost.shared.loadAXOnly(); log = WDAHost.shared.log.joined(separator: "\n") }
                    .buttonStyle(.bordered)
                Button("2 框架") { WDAHost.shared.loadXCTest(); log = WDAHost.shared.log.joined(separator: "\n") }
                    .buttonStyle(.bordered)
                Button("3 Session") { WDAHost.shared.probeSession(); log = WDAHost.shared.log.joined(separator: "\n") }
                    .buttonStyle(.bordered)
                Button("4 服务") { WDAHost.shared.startServer(); log = WDAHost.shared.log.joined(separator: "\n") }
                    .buttonStyle(.borderedProminent)
            }
            .font(.system(size: 12))

            ScrollView {
                Text(log)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            .foregroundColor(.green)
        }
        .padding()
        .onAppear {
            ControlServer().start(port: 10010)
            log = "AXTouch \(BuildInfo.tag) 已启动\nTCP 10010 就绪\n请按 1→2→3→4 顺序点"
        }
    }
}
