import SwiftUI
import Foundation
import Network
import Darwin

/// 照 AScript 架构：App 内自带整套 XCTest 框架 + WebDriverAgentLib，
/// 启动时按依赖顺序 dlopen，然后把 WDA 的 HTTP 服务器拉起来（8100），
/// 让任何 WDA 客户端（包括我们 PC 端）直接连。
final class WDAHost {
    static let shared = WDAHost()
    private(set) var log: [String] = []
    private var loaded: [String: UnsafeMutableRawPointer] = [:]
    var serverStarted = false

    private func append(_ s: String) {
        log.append(s)
        print("[WDAHost] \(s)")
    }

    private var fwDir: String {
        Bundle.main.bundlePath + "/Frameworks"
    }

    /// 按依赖顺序加载内嵌框架
    func loadAll() {
        guard loaded.isEmpty else { return }
        // 让内嵌 Frameworks 可被 @rpath 解析
        setenv("DYLD_FRAMEWORK_PATH", fwDir + ":" + (getenv("DYLD_FRAMEWORK_PATH").map { String(cString: $0) } ?? ""), 1)
        setenv("DYLD_LIBRARY_PATH", fwDir + ":" + (getenv("DYLD_LIBRARY_PATH").map { String(cString: $0) } ?? ""), 1)

        let order = [
            "Testing",
            "XCTestCore",
            "XCTAutomationSupport",
            "XCTest",
            "XCTestSupport",
            "XCUIAutomation",
            "XCUnit",
            "WebDriverAgentLib",
        ]
        for name in order {
            let path = "\(fwDir)/\(name).framework/\(name)"
            dlerror()
            if let h = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                loaded[name] = h
                append("✅ \(name)")
            } else if let e = dlerror() {
                append("❌ \(name): \(String(cString: e))")
            } else {
                append("❌ \(name)")
            }
        }
        // Swift 支持库
        let swiftLib = "\(fwDir)/libXCTestSwiftSupport.dylib"
        if dlopen(swiftLib, RTLD_NOW | RTLD_GLOBAL) != nil {
            append("✅ libXCTestSwiftSupport")
        } else {
            append("⚠️ libXCTestSwiftSupport")
        }
    }

    /// 启动 WDA 的 HTTP server（FBWebServer.startHTTPServer）
    func startServer() {
        loadAll()
        guard objc_getClass("FBWebServer") != nil else {
            append("❌ FBWebServer 类不存在（WebDriverAgentLib 未加载成功）")
            return
        }
        setenv("USE_PORT", "8100", 1)
        setenv("MJPEG_SERVER_PORT", "9100", 1)

        guard let cls = objc_getClass("FBWebServer") as? NSObject.Type else { return }
        let server = cls.init()
        if server.responds(to: NSSelectorFromString("startHTTPServer")) {
            server.perform(NSSelectorFromString("startHTTPServer"))
            serverStarted = true
            append("✅ 已调用 FBWebServer.startHTTPServer（8100）")
        } else {
            append("❌ FBWebServer 无 startHTTPServer")
            let methods = { () -> [String] in
                var out: [String] = []
                var count: UInt32 = 0
                if let mlist = class_copyMethodList(objc_getClass("FBWebServer"), &count) {
                    for i in 0..<Int(count) {
                        out.append(NSStringFromSelector(method_getName(mlist[i])))
                    }
                    free(mlist)
                }
                return out
            }()
            append("可用方法: \(methods.joined(separator: ", "))")
        }
    }

    func probe() -> [String: Any] {
        loadAll()
        var out: [String: Any] = ["log": log, "serverStarted": serverStarted]
        var cls: [String: Bool] = [:]
        for c in ["FBWebServer", "FBApplication", "FBXCTestDaemonsProxy", "XCUIDevice", "XCTRunnerDaemonSession", "XCUIApplication"] {
            cls[c] = objc_getClass(c) != nil
        }
        out["classes"] = cls
        return out
    }
}

/// TCP 控制服务：0.0.0.0:10010
final class ControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "axtouch.control")
    private var buffer = Data()

    func start(port: UInt16 = 10010) {
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: .tcp, on: p) else { return }
        listener = l
        l.newConnectionHandler = { conn in
            conn.start(queue: self.queue)
            self.handle(conn)
        }
        l.start(queue: queue)
        print("[ControlServer] listening \(port)")
    }

    private func handle(_ conn: NWConnection) {
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                if let data = data, !data.isEmpty { self.process(data: data, conn: conn) }
                if !done { receive() } else { conn.cancel() }
            }
        }
        receive()
    }

    private func process(data: Data, conn: NWConnection) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            var resp = "{\"ok\":false}"
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let cmd = obj["cmd"] as? String {
                switch cmd {
                case "probe":
                    let d = try? JSONSerialization.data(withJSONObject: WDAHost.shared.probe())
                    resp = String(data: d ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
                case "startserver":
                    WDAHost.shared.startServer()
                    Thread.sleep(forTimeInterval: 2)
                    resp = "{\"ok\":true,\"log\":\(jsonArr(WDAHost.shared.log))}"
                case "ping":
                    resp = "{\"ok\":true,\"pong\":true}"
                default:
                    resp = "{\"ok\":false,\"error\":\"unknown\"}"
                }
            }
            conn.send(content: (resp + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }

    private func jsonArr(_ a: [String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: a), encoding: .utf8)) ?? "[]"
    }
}

@main
struct AXTouchApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var log = "启动中…"

    var body: some View {
        VStack(spacing: 10) {
            Text("WDA 宿主").font(.title2).bold()
            ScrollView {
                Text(log)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            .foregroundColor(.green)
            HStack {
                Button("加载框架") {
                    WDAHost.shared.loadAll()
                    log = WDAHost.shared.log.joined(separator: "\n")
                }
                Button("启动 WDA 服务") {
                    WDAHost.shared.startServer()
                    log = WDAHost.shared.log.joined(separator: "\n")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            ControlServer().start(port: 10010)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                WDAHost.shared.loadAll()
                log = WDAHost.shared.log.joined(separator: "\n")
            }
        }
    }
}
