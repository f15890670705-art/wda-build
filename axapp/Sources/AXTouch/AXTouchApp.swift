import SwiftUI
import Combine
import Foundation
import Network
import Darwin

enum BuildInfo {
    static let version = "2.0"
    static let build = "38"
    static let tag = "v2.0-b38"
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
                case "status":
                    let ready = AXAgentIsReady()
                    let err = AXAgentLastError() ?? ""
                    let lp = AXAgentLogPath() ?? ""
                    resp = "{\"ok\":true,\"ready\":\(ready),\"err\":\"\(err)\",\"log\":\"\(lp)\"}"
                case "agent":
                    AXAgentStartSticky()
                    resp = "{\"ok\":true,\"note\":\"bootstrap started\"}"
                case "tap":
                    let x = (obj["x"] as? Double) ?? 0
                    let y = (obj["y"] as? Double) ?? 0
                    let r = AXAgentTap(x, y)
                    resp = "{\"ok\":\(r)}"
                case "swipe":
                    let r = AXAgentSwipe((obj["x1"] as? Double) ?? 0, (obj["y1"] as? Double) ?? 0,
                                         (obj["x2"] as? Double) ?? 0, (obj["y2"] as? Double) ?? 0,
                                         (obj["duration"] as? Double) ?? 0.25)
                    resp = "{\"ok\":\(r)}"
                case "longpress":
                    let r = AXAgentLongPress((obj["x"] as? Double) ?? 0, (obj["y"] as? Double) ?? 0,
                                             (obj["duration"] as? Double) ?? 1.0)
                    resp = "{\"ok\":\(r)}"
                case "touch":
                    if let evs = obj["events"] as? [[String: Any]], evs.count >= 2 {
                        var xy = [Double]()
                        var ts = [Double]()
                        var acc = 0.0
                        for e in evs {
                            xy.append((e["x"] as? Double) ?? 0)
                            xy.append((e["y"] as? Double) ?? 0)
                            acc += (e["delay"] as? Double) ?? 0
                            ts.append(acc)
                        }
                        var ok = false
                        xy.withUnsafeBufferPointer { xb in
                            ts.withUnsafeBufferPointer { tb in
                                ok = AXAgentGesture(xb.baseAddress!, tb.baseAddress!, Int32(evs.count))
                            }
                        }
                        resp = "{\"ok\":\(ok)}"
                    } else {
                        resp = "{\"ok\":false,\"error\":\"需要 events 数组(>=2 点)\"}"
                    }
                case "shot":
                    let maxSide = (obj["max"] as? Double) ?? 720
                    let q = (obj["quality"] as? Double) ?? 0.6
                    if let b64 = AXAgentShot(maxSide, q) {
                        resp = "{\"ok\":true,\"w\":0,\"jpeg\":\"\(b64)\"}"
                    } else {
                        resp = "{\"ok\":false,\"error\":\"shot failed\"}"
                    }
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
    @State private var agentReady = false
    private let readyTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            Text("AXTouch \(BuildInfo.tag)").font(.title2).bold()
            Text(agentReady ? "AGENT READY ✅  (Automation 会话已建立)" : "AGENT —  正在建立会话…")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(agentReady ? .green : .orange)
            Text("TCP 0.0.0.0:10010  |  日志: Documents/agent.log + axtouch.log")
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
            // 自动执行 AXAgent bootstrap（复刻 ASAgen：DDI 框架 → daemon session → 自动化模式）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AXAgentStartSticky()   // 常驻线程里 bootstrap，XPC 连接不会被释放
                log = WDAHost.shared.log.joined(separator: "\n")
            }
            log = WDAHost.shared.log.joined(separator: "\n")
        }
        .onReceive(readyTimer) { _ in
            agentReady = AXAgentIsReady()
        }
    }
}
