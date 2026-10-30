import SwiftUI
import Combine
import Foundation
import Network
import Darwin

enum BuildInfo {
    static let version = "2.0"
    static let build = "74"
    static let tag = "v2.0-b77"
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
/// 清空指定日志文件（截断成 0 字节）。用于 {"cmd":"logclear","file":"xxx"}
func AXClearLogFileJSON(_ name: String) -> String {
    let dir = AXDocumentsURL()
    var fileName = name
    if !fileName.lowercased().hasSuffix(".log") { fileName += ".log" }
    let url = dir.appendingPathComponent(fileName)

    var dict: [String: Any] = ["ok": false, "file": url.path]
    let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
    let before = (attr?[.size] as? NSNumber)?.int64Value ?? 0
    do {
        try Data().write(to: url, options: .atomic)
        dict["ok"] = true
    } catch {
        dict["error"] = error.localizedDescription
    }
    dict["freedKB"] = Int(before / 1024)
    guard let out = try? JSONSerialization.data(withJSONObject: dict) else { return "{\"ok\":false}" }
    return String(data: out, encoding: .utf8) ?? "{\"ok\":false}"
}

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
                case "pinch":
                    /* {"cmd":"pinch","cx":215,"cy":466,"gap0":100,"gap1":300,"dur":0.35}
                       gap0<gap1 = 双指张开(放大)；gap0>gap1 = 捏合(缩小) */
                    let pin = AXAgentPinch((obj["cx"] as? Double) ?? 0,
                                           (obj["cy"] as? Double) ?? 0,
                                           (obj["gap0"] as? Double) ?? 200,
                                           (obj["gap1"] as? Double) ?? 200,
                                           (obj["dur"] as? Double) ?? 0.35)
                    resp = "{\"ok\":\(pin)}"
                case "text":
                    /* {"cmd":"text","v":"hello"} —— ASCII 直打；中文用 paste */
                    let tv = (obj["v"] as? String) ?? ""
                    resp = "{\"ok\":\(AXAgentTypeText(tv))}"
                case "key":
                    /* {"cmd":"key","v":"\r","mods":0}   mods: Shift=131072 Cmd=1048576 */
                    let kv = (obj["v"] as? String) ?? ""
                    let md = (obj["mods"] as? Int) ?? 0
                    resp = "{\"ok\":\(AXAgentKey(kv, UInt(max(0, md))))}"
                case "paste":
                    /* {"cmd":"paste","v":"中文内容"} —— 写剪贴板 + Cmd+V */
                    let pv = (obj["v"] as? String) ?? ""
                    resp = "{\"ok\":\(AXAgentPaste(pv))}"
                case "pbset":
                    resp = "{\"ok\":\(AXAgentPasteboardSet((obj["v"] as? String) ?? ""))}"
                case "pbget":
                    let pb = AXAgentPasteboardGet() ?? ""
                    let pd: [String: Any] = ["ok": true, "text": pb]
                    resp = (try? String(data: JSONSerialization.data(withJSONObject: pd), encoding: .utf8)) ?? "{\"ok\":false}"
                case "touchseq":
                    /* 流式触控实验：
                       {"cmd":"touchseq","mode":0|1,"x1":100,"y1":300,"x2":300,"y2":700,"steps":12,"gap":20}
                       mode 0 = 整段一次提交（对照）；mode 1 = 分段 + persistent state（实验） */
                    let r = AXAgentTouchSeq(Int32((obj["mode"] as? Int) ?? 0),
                                            (obj["x1"] as? Double) ?? 0,
                                            (obj["y1"] as? Double) ?? 0,
                                            (obj["x2"] as? Double) ?? 0,
                                            (obj["y2"] as? Double) ?? 0,
                                            Int32((obj["steps"] as? Int) ?? 12),
                                            Int32((obj["gap"] as? Int) ?? 20)) ?? "nil"
                    let d: [String: Any] = ["ok": true, "result": r]
                    resp = (try? String(data: JSONSerialization.data(withJSONObject: d), encoding: .utf8)) ?? "{\"ok\":false}"
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
                case "ldudid":
                    /* 异步启动 lockdown UDID 探测（b58：控制队列绝不阻塞） */
                    let st = AXLockdownUDIDStart() ?? "nil"
                    resp = "{\"ok\":true,\"state\":\"\(st)\"}"
                case "ldudidresult":
                    let lr = AXLockdownUDIDResult() ?? "idle"
                    let ld: [String: Any] = ["ok": true, "result": lr]
                    resp = (try? String(data: JSONSerialization.data(withJSONObject: ld), encoding: .utf8)) ?? "{\"ok\":false}"
                case "getudid":
                    let cur = AXStreamCurrentUDID() ?? ""
                    resp = "{\"ok\":true,\"udid\":\"\(cur)\"}"
                case "home":
                    resp = "{\"ok\":\(AXAgentPressHome())}"
                case "devinfo":
                    DispatchQueue.global().async { _ = AXProbeDeviceInfo() }
                    resp = "{\"ok\":true,\"note\":\"结果看 agent.log\"}"
                case "udid":
                    /* {"cmd":"udid","v":"00008120-xxxx"} —— PC 端把真 UDID 传给手机侧 */
                    let uv = (obj["v"] as? String) ?? ""
                    AXStreamSetUDIDPersist(uv)   /* ★ 持久化：重装/重启都还在 */
                    resp = "{\"ok\":true,\"udid\":\"\(uv)\"}"
                case "profile":
                    /* 测试档位（临时）：
                       {"cmd":"profile"}                    → 列出所有档位 + 当前值
                       {"cmd":"profile","i":2}              → 切到 2 号档（采集变了会自动重启服务）
                       {"cmd":"profile","i":4,"restart":1}  → 强制重启服务 */
                    let cnt = Int(AXStreamProfileCount())
                    let cur = UserDefaults.standard.integer(forKey: "axtouch.stream.scheme")
                    if let idx = obj["i"] as? Int, idx >= 0 && idx < cnt {
                        let capBefore = Int(AXStreamGetScheme())
                        UserDefaults.standard.set(idx, forKey: "axtouch.stream.scheme")
                        AXStreamApplyProfile(Int32(idx))
                        let capNew = Int(AXStreamProfileCapture(Int32(idx)))
                        let force = ((obj["restart"] as? Int) ?? 0) == 1
                        let needRestart = force || (capBefore != capNew)
                        if needRestart {
                            AXStreamStop()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                _ = AXStreamStart(27184)
                            }
                        }
                        let d: [String: Any] = [
                            "ok": true, "i": idx,
                            "name": String(cString: AXStreamProfileName(Int32(idx))),
                            "desc": String(cString: AXStreamProfileDesc(Int32(idx))),
                            "restarting": needRestart,
                        ]
                        resp = (try? String(data: JSONSerialization.data(withJSONObject: d), encoding: .utf8)) ?? "{\"ok\":false}"
                    } else {
                        var items = [[String: Any]]()
                        for i in 0..<cnt {
                            items.append([
                                "i": i,
                                "name": String(cString: AXStreamProfileName(Int32(i))),
                                "desc": String(cString: AXStreamProfileDesc(Int32(i))),
                                "capture": Int(AXStreamProfileCapture(Int32(i))),
                            ])
                        }
                        let d: [String: Any] = ["ok": true, "count": cnt, "current": cur, "items": items]
                        resp = (try? String(data: JSONSerialization.data(withJSONObject: d), encoding: .utf8)) ?? "{\"ok\":false}"
                    }
                case "quality":
                    /* {"cmd":"quality","fps":30,"bitrate":2000000,"maxSide":720}
                       只给需要的字段，0/缺省=保持。fps 与码率立刻生效，maxSide 变则重建编码会话 */
                    let qf = (obj["fps"] as? Int) ?? 0
                    let qb = (obj["bitrate"] as? Int) ?? 0
                    let qm = (obj["maxSide"] as? Int) ?? 0
                    if let iq = obj["imgq"] as? Double { AXStreamSetImgQuality(iq) }
                    if let iu = obj["imguti"] as? String { AXStreamSetImgFormat(iu) }
                    if let dm = obj["dec"] as? String { AXStreamSetDecodeMode(dm == "thumb" ? 1 : 0) }
                    if let sd = obj["staticDrop"] as? Int { AXStreamSetStaticDrop(Int32(sd)) }
                    if let sf = obj["staticFps"] as? Int { AXStreamSetStaticFps(Int32(sf)) }
                    if let pm = obj["pauseMs"] as? Int { AXStreamSetPauseMs(Int32(pm)) }
                    AXStreamSetParams(Int32(qb), Int32(qf), Int32(qm))
                    resp = "{\"ok\":true,\"fps\":\(qf),\"bitrate\":\(qb),\"maxSide\":\(qm)}"
                case "bench":
                    /* {"cmd":"bench","mode":0..4} —— 发热定位用的分段跑
                       0=正常 1=只截图 2=到缩放为止 3=只编码发送 4=空转 */
                    let bm = (obj["mode"] as? Int) ?? 0
                    AXStreamSetBenchMode(Int32(bm))
                    resp = "{\"ok\":true,\"bench\":\(bm)}"
                case "stream":
                    /* {"cmd":"stream","op":"start|stop|status"} */
                    let op = (obj["op"] as? String) ?? "status"
                    if op == "start" {
                        let port = UInt16((obj["port"] as? Int) ?? 27184)
                        if let br = obj["bitrate"] as? Int { AXStreamSetParams(Int32(br), 0, 0) }
                        if let fp = obj["fps"] as? Int { AXStreamSetParams(0, Int32(fp), 0) }
                        if let ms = obj["maxSide"] as? Int { AXStreamSetParams(0, 0, Int32(ms)) }
                        let ok = AXStreamStart(port)
                        resp = "{\"ok\":\(ok)}"
                    } else if op == "stop" {
                        AXStreamStop()
                        resp = "{\"ok\":true}"
                    } else {
                        let st = AXStreamStats()
                        resp = (try? String(data: JSONSerialization.data(withJSONObject: st), encoding: .utf8)) ?? "{}"
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
                case "logclear", "logdel":
                    /* {"cmd":"logclear"} —— 清空运行日志（文件截断成 0 字节）
                       可选 {"file":"axtouch"} 清别的日志文件。 */
                    let lcName = (obj["file"] as? String) ?? "agent"
                    if lcName == "agent" {
                        var freed: Int64 = 0
                        let ok = AXAgentLogClear(&freed)
                        resp = "{\"ok\":\(ok),\"freedKB\":\(freed / 1024)}"
                    } else {
                        resp = AXClearLogFileJSON(lcName)
                    }
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
