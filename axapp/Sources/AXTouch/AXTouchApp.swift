import SwiftUI
import Foundation
import Network
import Darwin

enum BuildInfo {
    static let version = "2.0"
    static let build = "30"
    static let tag = "v2.0-b30"
}

/// 文件日志：所有输出同步写入 Documents/axtouch.log（PC 端通过 house_arrest/AFC 随时拉取）
enum FileLog {
    static let path: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? "/tmp"
        return docs + "/axtouch.log"
    }()

    static func write(_ s: String) {
        let line = "\(Date()) [\(BuildInfo.tag)] \(s)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// 分步加载。框架加载与 WDA 服务全部走常驻线程（XPC 保活）。
final class WDAHost {
    static let shared = WDAHost()
    private(set) var log: [String] = []
    private var loaded: [String: UnsafeMutableRawPointer] = [:]
    var serverStarted = false
    var frameworksLoaded = false

    func append(_ s: String) {
        log.append(s)
        NSLog("[WDHost] %@", s)
        FileLog.write(s)
    }

    func clear() { log.removeAll() }

    private var fwDir: String { Bundle.main.bundlePath + "/Frameworks" }

    var loadedCount: Int { loaded.count }

    func loadAXOnly() {
        let p = fwDir + "/AXRuntime.framework/AXRuntime"
        if dlopen(p, RTLD_NOW) != nil {
            append("✅[1] AXRuntime（内嵌）")
            return
        }
        if dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW) != nil {
            append("✅[1] AXRuntime（系统）")
        } else {
            append("❌[1] AXRuntime 加载失败")
        }
    }

    func probeSessionMainThread_forbidden() {
        append("--- 探测 XCTRunnerDaemonSession（主线程，已知有 XPC 释放风险）---")
        if let e = AXProbeDaemonSession() {
            append("⚠️[3] 异常:")
            append(String(e.prefix(600)))
        } else {
            append("✅[3] sharedSession 成功")
        }
    }

    func probe() -> [String: Any] {
        var out: [String: Any] = ["tag": BuildInfo.tag, "log": log,
                                  "loaded": loadedCount, "server": serverStarted]
        var cls: [String: Bool] = [:]
        for c in ["FBWebServer", "FBApplication", "FBXCTestDaemonsProxy", "XCUIDevice", "XCTRunnerDaemonSession"] {
            cls[c] = objc_getClass(c) != nil
        }
        out["classes"] = cls
        out["logfile"] = FileLog.path
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
                case "load": AXLoadXCTestThread(); resp = "{\"ok\":true}"
                case "server": AXStartWDAServerThread(nil); resp = "{\"ok\":true}"
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
            Text("TCP 0.0.0.0:10010  |  日志: Documents/axtouch.log")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Button("1 AX") { WDAHost.shared.loadAXOnly(); log = WDAHost.shared.log.joined(separator: "\n") }
                    .buttonStyle(.bordered)
                Button("2 框架") { AXLoadXCTestThread(); log = "已转常驻线程加载（结果看 axtouch.log / syslog）" }
                    .buttonStyle(.bordered)
                Button("3 Session") { WDAHost.shared.probeSessionMainThread_forbidden(); log = WDAHost.shared.log.joined(separator: "\n") }
                    .buttonStyle(.bordered)
                Button("7 boot") {
                    DispatchQueue.global().async {
                        let r = AXBootstrapProbe() ?? "nil"
                        WDAHost.shared.append(r)
                        FileLog.write(r)
                    }
                }
                    .buttonStyle(.bordered)
                Button("5 sock") {
                    let r = AXTestLocalSocket() ?? "nil"
                    WDAHost.shared.append(r)
                    log = r
                }
                    .buttonStyle(.bordered)
                Button("7 扫描") {
                    DispatchQueue.global().async {
                        let r = AXScanLoopbackPorts() ?? "nil"
                        WDAHost.shared.append("::1 可达端口: \(r)")
                        FileLog.write("::1 端口扫描结果: \(r)")
                    }
                }
                    .buttonStyle(.bordered)
                Button("6 lockdown") {
                    let r = AXTestLockdownTCP() ?? "nil"
                    WDAHost.shared.append(r)
                    log = r
                }
                    .buttonStyle(.bordered)
                Button("4 服务") { AXStartWDAServerThread(nil); log = "服务已在常驻线程启动\nPC 验证: curl http://手机IP:8100/status" }
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
            WDAHost.shared.append("App 启动 \(BuildInfo.tag)，日志文件: \(FileLog.path)")
            log = WDAHost.shared.log.joined(separator: "\n")
        }
    }
}
