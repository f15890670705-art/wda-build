import SwiftUI
import Foundation
import Network
import Darwin

/// 合成版（照 AScript 架构）：
/// 1. dlopen AXRuntime + XCUIAutomation（多路径多模式，失败记录 dlerror 原文）
/// 2. 触控优先级：eventSynthesizer（XCUIAutomation）→ AXUIElement(AXPress)
/// 3. TCP 控制服务 10010：{"cmd":"tap","x":..,"y":..} / {"cmd":"probe"} / {"cmd":"ping"}
final class AXEngine {
    static let shared = AXEngine()

    private var axHandle: UnsafeMutableRawPointer?
    private var xcuiHandle: UnsafeMutableRawPointer?
    private var createSystemWide: (@convention(c) () -> AnyObject?)?
    private var copyElementAtPosition: (@convention(c) (AnyObject, Float, Float, UnsafeMutablePointer<AnyObject?>?) -> Int32)?
    private var performAction: (@convention(c) (AnyObject, CFString) -> Int32)?

    private(set) var bootLog: [String] = []
    var xcuiAvailable = false
    var deviceObj: AnyObject?
    var synthObj: AnyObject?

    private func log(_ s: String) { bootLog.append(s) }

    func boot() {
        guard axHandle == nil else { return }

        // ---- AXRuntime ----
        let axPath = "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime"
        dlerror()
        if let h = dlopen(axPath, RTLD_NOW | RTLD_GLOBAL) {
            axHandle = h
            log("✅ AXRuntime")
            createSystemWide = unsafeBitCast(dlsym(h, "AXUIElementCreateSystemWide"), to: (@convention(c) () -> AnyObject?).self)
            copyElementAtPosition = unsafeBitCast(dlsym(h, "AXUIElementCopyElementAtPosition"), to: (@convention(c) (AnyObject, Float, Float, UnsafeMutablePointer<AnyObject?>?) -> Int32).self)
            performAction = unsafeBitCast(dlsym(h, "AXUIElementPerformAction"), to: (@convention(c) (AnyObject, CFString) -> Int32).self)
        } else if let e = dlerror() {
            log("❌ AXRuntime: \(String(cString: e))")
        } else {
            log("❌ AXRuntime")
        }

        // ---- XCUIAutomation（AScript 同路径，先加载它的依赖）----
        let deps: [(String, String)] = [
            ("XCTAutomationSupport", "/System/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport"),
            ("XCTestCore", "/System/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore"),
            ("XCTestSupport", "/System/Library/PrivateFrameworks/XCTestSupport.framework/XCTestSupport"),
        ]
        for (n, p) in deps {
            dlerror()
            if dlopen(p, RTLD_NOW | RTLD_GLOBAL) != nil { log("✅ \(n)") }
            else if let e = dlerror() { log("⚠️ \(n): \(String(cString: e))") }
            else { log("⚠️ \(n)") }
        }
        dlerror()
        let xcuiPath = "/System/Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation"
        if let h = dlopen(xcuiPath, RTLD_NOW | RTLD_GLOBAL) {
            xcuiHandle = h
            xcuiAvailable = true
            log("✅ XCUIAutomation —— eventSynthesizer 路线可用!")
        } else if let e = dlerror() {
            xcuiAvailable = false
            log("❌ XCUIAutomation: \(String(cString: e))")
        } else {
            xcuiAvailable = false
            log("❌ XCUIAutomation")
        }

        // ---- XCUIDevice.sharedDevice().eventSynthesizer ----
        if xcuiAvailable, let cls = objc_getClass("XCUIDevice") {
            if let dev = (cls as AnyObject).perform(NSSelectorFromString("sharedDevice"))?.takeRetainedValue() {
                deviceObj = dev
                if let es = dev.perform(NSSelectorFromString("eventSynthesizer"))?.takeUnretainedValue() {
                    synthObj = es
                    log("✅ eventSynthesizer 就绪: \(es)")
                } else {
                    log("❌ eventSynthesizer 为 nil")
                }
            } else {
                log("❌ sharedDevice 为 nil")
            }
        }
    }

    /// 合成点击。优先 XCUIAutomation eventSynthesizer，失败回退 AX。
    func tap(x: Double, y: Double) -> [String: Any] {
        boot()
        // 1) eventSynthesizer 路线
        if let es = synthObj {
            let sel = NSSelectorFromString("pressAtPoint:radius:orientation:touchNumber:")
            if es.responds(to: sel) {
                let imp = es.method(for: sel)
                typealias Fn = @convention(c) (AnyObject, Selector, CGPoint, CGFloat, Int, Int) -> Void
                let fn = unsafeBitCast(imp, to: Fn.self)
                fn(es, sel, CGPoint(x: x, y: y), 0, 1, 1)
                // press 即按下+抬起（XCTest 语义里 press 是完整点击）
                return ["ok": true, "via": "eventSynthesizer"]
            }
            let sel2 = NSSelectorFromString("pressAtPoint:radius:orientation:")
            if es.responds(to: sel2) {
                let imp = es.method(for: sel2)
                typealias Fn2 = @convention(c) (AnyObject, Selector, CGPoint, CGFloat, Int) -> Void
                let fn = unsafeBitCast(imp, to: Fn2.self)
                fn(es, sel2, CGPoint(x: x, y: y), 0, 1)
                return ["ok": true, "via": "eventSynthesizer"]
            }
        }
        // 2) AX 路线
        guard let createSystemWide, let copyElementAtPosition, let performAction else {
            return ["ok": false, "error": "无可用触控路线"]
        }
        guard let sys = createSystemWide() else {
            return ["ok": false, "error": "CreateSystemWide nil"]
        }
        var element: AnyObject?
        let err = copyElementAtPosition(sys, Float(x), Float(y), &element)
        guard err == 0, let el = element else {
            return ["ok": false, "error": "AX CopyElementAtPosition err=\(err) (-25200=权限拒绝)"]
        }
        let pressErr = performAction(el, "AXPress" as CFString)
        return ["ok": pressErr == 0, "via": "AX", "err": pressErr]
    }

    func probeDict() -> [String: Any] {
        boot()
        var out: [String: Any] = [
            "xcuiAvailable": xcuiAvailable,
            "eventSynthesizer": synthObj != nil,
            "bootLog": bootLog,
        ]
        if let h = axHandle {
            var syms: [String: Bool] = [:]
            for s in ["AXUIElementCreateSystemWide", "AXUIElementCopyElementAtPosition", "AXUIElementPerformAction"] {
                syms[s] = dlsym(h, s) != nil
            }
            out["axSymbols"] = syms
        }
        return out
    }
}

/// TCP 控制服务：0.0.0.0:10010，行协议 JSON。
final class ControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "axtouch.control")
    private var buffer = Data()

    func start(port: UInt16 = 10010) {
        let params = NWParameters.tcp
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else { return }
        listener = l
        l.newConnectionHandler = { conn in
            conn.start(queue: self.queue)
            self.handle(conn)
        }
        l.start(queue: queue)
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
            let resp: String
            if let obj = try? JSONSerialization.jsonObject(with: line.data(using: .utf8) ?? Data()) as? [String: Any],
               let cmd = obj["cmd"] as? String {
                switch cmd {
                case "tap":
                    let x = (obj["x"] as? NSNumber)?.doubleValue ?? 0
                    let y = (obj["y"] as? NSNumber)?.doubleValue ?? 0
                    resp = jsonStr(AXEngine.shared.tap(x: x, y: y))
                case "probe":
                    resp = jsonStr(AXEngine.shared.probeDict())
                case "ping":
                    resp = #"{"ok":true,"pong":true}"#
                default:
                    resp = #"{"ok":false,"error":"unknown cmd"}"#
                }
            } else {
                resp = #"{"ok":false,"error":"bad json"}"#
            }
            conn.send(content: (resp + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }

    private func jsonStr(_ obj: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}

@main
struct AXTouchApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var log: String = "启动中…"

    var body: some View {
        VStack(spacing: 10) {
            Text("AXTouch 触控引擎").font(.title2).bold()
            Text("TCP 0.0.0.0:10010\n{\"cmd\":\"tap\",\"x\":196,\"y\":420}")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
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
                Button("引擎状态") { AXEngine.shared.boot(); log = AXEngine.shared.bootLog.joined(separator: "\n") }
                    .buttonStyle(.bordered)
                Button("测试点击") {
                    let r = AXEngine.shared.tap(x: 196, y: 420)
                    log = String(describing: r)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            ControlServer().start(port: 10010)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AXEngine.shared.boot()
                log = AXEngine.shared.bootLog.joined(separator: "\n")
            }
        }
    }
}
