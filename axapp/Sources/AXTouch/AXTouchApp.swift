import SwiftUI
import Combine
import Foundation
import Network
import Darwin

enum BuildInfo {
    static let version = "2.0"
    static let build = "47"
    static let tag = "v2.0-b47"
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

/// Documents 目录
func AXDocumentsURL() -> URL {
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

/// 列出 Documents 下所有 .log（JSON 一行返回）
func AXListLogsJSON() -> String {
    let dir = AXDocumentsURL()
    let fm = FileManager.default
    var items: [[String: Any]] = []
    if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
        for n in names where n.lowercased().hasSuffix(".log") {
            let p = dir.appendingPathComponent(n)
            let attr = try? fm.attributesOfItem(atPath: p.path)
            let sz = (attr?[.size] as? NSNumber)?.intValue ?? 0
            let mt = (attr?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            items.append(["name": n, "size": sz, "mtime": mt])
        }
    }
    items.sort { ($0["mtime"] as? Double ?? 0) > ($1["mtime"] as? Double ?? 0) }
    let dict: [String: Any] = ["ok": true, "dir": dir.path, "logs": items]
    guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return "{\"ok\":false}" }
    return String(data: d, encoding: .utf8) ?? "{\"ok\":false}"
}

/// 读日志尾部 maxKB 千字节，JSON 返回（text 已转义，可安全塞进一行）
func AXReadLogJSON(_ name: String, _ maxKB: Int) -> String {
    let dir = AXDocumentsURL()
    /* 允许 "agent" / "axtouch" 简写，也允许直接给文件名 */
    var fileName = name
    if !fileName.lowercased().hasSuffix(".log") { fileName += ".log" }
    let url = dir.appendingPathComponent(fileName)

    var dict: [String: Any] = ["ok": false, "file": url.path]
    guard let fh = try? FileHandle(forReadingFrom: url) else {
        dict["error"] = "打不开（文件不存在？）"
        return (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}"
    }
    defer { _ = try? fh.close() }

    let size: UInt64 = fh.seekToEndOfFile()
    let want = UInt64(max(1, min(maxKB, 16384))) * 1024
    let from: UInt64 = size > want ? size - want : 0
    _ = try? fh.seek(toOffset: from)

    /* readToEnd() 返回 Data? 且 throws ⇒ Swift 5 的 try? 自动展平成 Data? */
    var data = Data()
    if let got = try? fh.readToEnd() { data = got }
    let d = data

    /* 从中间截断可能切在多字节字符中间：丢掉开头最多 3 字节直到能解码 */
    var text = ""
    for skip in 0...3 {
        if skip >= d.count { break }
        if let s = String(data: d.subdata(in: skip..<d.count), encoding: .utf8) {
            text = s
            break
        }
    }
    if text.isEmpty { text = String(decoding: d, as: UTF8.self) }

    dict["ok"] = true
    dict["size"] = Int(size)
    dict["from"] = Int(from)
    dict["bytes"] = d.count
    dict["text"] = text
    guard let out = try? JSONSerialization.data(withJSONObject: dict) else { return "{\"ok\":false}" }
    return String(data: out, encoding: .utf8) ?? "{\"ok\":false}"
}

/// 每条连接独立的接收缓冲（原来的 buffer 是 ControlServer 的成员，
/// 多个客户端同时连会互相串包）
private final class AXConn {
    let c: NWConnection
    var buf = Data()
    init(_ c: NWConnection) { self.c = c }
}

/// TCP 控制 10010
final class ControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ax.ctl")

    func start(port: UInt16 = 10010) {
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: .tcp, on: p) else { return }
        listener = l
        l.newConnectionHandler = { c in
            c.start(queue: self.queue)
            let conn = AXConn(c)
            self.handle(conn)
        }
        l.start(queue: queue)
    }

    private func handle(_ conn: AXConn) {
        func rec() {
            conn.c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, _ in
                if let d = d, !d.isEmpty { self.process(d, conn) }
                if !done { rec() } else { conn.c.cancel() }
            }
        }
        rec()
    }

    private func process(_ data: Data, _ conn: AXConn) {
        conn.buf.append(data)
        while let nl = conn.buf.firstIndex(of: 0x0A) {
            let ld = conn.buf[conn.buf.startIndex..<nl]
            conn.buf.removeSubrange(conn.buf.startIndex...nl)
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
                case "recprobe":
                    DispatchQueue.global().async { _ = AXAgentProbeRecording() }
                    resp = "{\"ok\":true,\"note\":\"probe started, 4s later check agent.log\"}"
                case "apptimeout":
                    /* {"cmd":"apptimeout","v":0.01} —— 调 _XCTSetApplicationStateTimeout */
                    let v = (obj["v"] as? Double) ?? 0.01
                    let r = AXAgentSetAppStateTimeout(v)
                    resp = "{\"ok\":\(r),\"v\":\(v)}"
                case "shot2":
                    /* 底层截图：跳过 XCUIScreen 三层包装，直接打 screenshotIPCInterface
                       mode 0 = 整屏, 1 = 半屏 rect 试验 */
                    let md = (obj["mode"] as? Int) ?? 0
                    let q2 = (obj["quality"] as? Double) ?? 0.6
                    let r2 = AXAgentShotLowLevel(Int32(md), q2) ?? "nil"
                    if r2.count > 1000 {
                        resp = "{\"ok\":true,\"jpeg\":\"\(r2)\"}"
                    } else {
                        resp = "{\"ok\":false,\"error\":\"\(r2)\"}"
                    }
                case "tree":
                    /* {"cmd":"tree","max":120} → 读 AX 元素树，详情写 agent.log */
                    let mx = (obj["max"] as? Int) ?? 120
                    let r = AXAgentDumpTree(Int32(mx)) ?? "nil"
                    resp = "{\"ok\":true,\"result\":\"\(r)\"}"
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
                case "logs":
                    resp = AXListLogsJSON()
                case "log":
                    /* {"cmd":"log","file":"agent","kb":5120}
                       默认 5MB（上限 16MB）；file 可给 agent / axtouch / xxx.log */
                    let name = (obj["file"] as? String) ?? "agent"
                    let kb = (obj["kb"] as? Int) ?? 5120
                    resp = AXReadLogJSON(name, kb)
                case "load": AXLoadXCTestThread(); resp = "{\"ok\":true}"
                case "server": AXStartWDAServerThread(nil); resp = "{\"ok\":true}"
                default: resp = "{\"ok\":false,\"error\":\"unknown\"}"
                }
            }
            conn.c.send(content: (resp + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }
}

@main
struct AXTouchApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// UIKit 主界面（AXMainViewController，照 ios-daemon 卡片式 UI）挂进 SwiftUI
struct AXUIKitHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        AXMakeRootController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct ContentView: View {
    /// 只在首帧启动一次服务与会话，避免 SwiftUI 重复重建 body 时重复起监听
    @State private var booted = false

    var body: some View {
        AXUIKitHost()
            .ignoresSafeArea()          // VC 内部用 safeAreaLayoutGuide 自己避让
            .onAppear {
                guard !booted else { return }
                booted = true
                ControlServer().start(port: 10010)
                WDAHost.shared.append("App 启动 \(BuildInfo.tag)，日志文件: \(FileLog.path)")
                // 自动执行 AXAgent bootstrap（复刻 ASAgen：DDI 框架 → daemon session → 自动化模式）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    AXAgentStartSticky()   // 常驻线程里 bootstrap，XPC 连接不会被释放
                }
            }
    }
}
