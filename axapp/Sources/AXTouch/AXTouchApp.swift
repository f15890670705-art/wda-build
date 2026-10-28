import SwiftUI
import Foundation
import Network

/// AX 触控验证 + TCP 控制服务（端口 10010）。
/// 协议：每行一个 JSON 请求，如 {"cmd":"tap","x":196,"y":420}
/// 响应：{"ok":true,"err":0} 或 {"ok":false,"error":"..."}
final class AXBridge {
    static let shared = AXBridge()

    private typealias CreateSystemWideFn = @convention(c) () -> AnyObject?
    private typealias CopyElementAtPositionFn = @convention(c) (AnyObject, Float, Float, UnsafeMutablePointer<AnyObject?>?) -> Int32
    private typealias PerformActionFn = @convention(c) (AnyObject, CFString) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var createSystemWide: CreateSystemWideFn?
    private var copyElementAtPosition: CopyElementAtPositionFn?
    private var performAction: PerformActionFn?

    private(set) var loadError: String = "未加载"

    func load() {
        guard handle == nil else { return }
        let p = "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime"
        guard let h = dlopen(p, RTLD_NOW) else {
            loadError = "dlopen 失败"
            return
        }
        handle = h
        loadError = "AXRuntime 已加载"
        if let sym = dlsym(h, "AXUIElementCreateSystemWide") {
            createSystemWide = unsafeBitCast(sym, to: CreateSystemWideFn.self)
        }
        if let sym = dlsym(h, "AXUIElementCopyElementAtPosition") {
            copyElementAtPosition = unsafeBitCast(sym, to: CopyElementAtPositionFn.self)
        }
        if let sym = dlsym(h, "AXUIElementPerformAction") {
            performAction = unsafeBitCast(sym, to: PerformActionFn.self)
        }
    }

    /// 在屏幕坐标 (x,y) 处按一下（AXPress）。
    @discardableResult
    func tap(x: CGFloat, y: CGFloat) -> [String: Any] {
        load()
        guard let createSystemWide, let copyElementAtPosition, let performAction else {
            return ["ok": false, "error": "函数未就绪: \(loadError)"]
        }
        guard let sys = createSystemWide() else {
            return ["ok": false, "error": "CreateSystemWide 返回 nil"]
        }
        var element: AnyObject?
        let err = copyElementAtPosition(sys, Float(x), Float(y), &element)
        guard err == 0, let el = element else {
            return ["ok": false, "error": "CopyElementAtPosition err=\(err)"]
        }
        let pressErr = performAction(el, "AXPress" as CFString)
        return ["ok": pressErr == 0, "err": pressErr]
    }

    func probe() -> String {
        var out: [String] = []
        // 按依赖顺序、RTLD_NOW|GLOBAL（AScript 同款路径），失败打 dlerror 原文
        let frameworks: [(String, String)] = [
            ("AXRuntime", "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime"),
            ("XCTAutomationSupport", "/System/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport"),
            ("XCTestCore", "/System/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore"),
            ("XCUIAutomation", "/System/Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation"),
            ("UITesting", "/System/Library/PrivateFrameworks/UITesting.framework/UITesting"),
            ("XCTest", "/System/Developer/Library/Frameworks/XCTest.framework/XCTest"),
        ]
        out.append("== dlopen (RTLD_NOW|GLOBAL) ==")
        for (name, path) in frameworks {
            dlerror()  // 清空旧错误
            if let h = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                out.append("✅ \(name)")
            } else if let e = dlerror() {
                out.append("❌ \(name): \(String(cString: e))")
            } else {
                out.append("❌ \(name): 失败(无dlerror)")
            }
        }
        // ObjC 类存在性（XCUIAutomation 加载成功的话这些类会出现）
        out.append("== ObjC 类 ==")
        for cls in ["XCUIDevice", "XCTRunnerDaemonSession", "XCSynthesizedEventRecord", "XCUIApplicationImpl"] {
            out.append("\(objc_getClass(cls) != nil ? "✅" : "❌") class \(cls)")
        }
        // AX 符号
        if let h = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW) {
            out.append("== AX 符号 ==")
            for s in ["AXUIElementCreateSystemWide", "AXUIElementCopyElementAtPosition", "AXUIElementPerformAction"] {
                out.append("\(dlsym(h, s) != nil ? "✅" : "❌") \(s)")
            }
        }
        return out.joined(separator: "\n")
    }
}

/// TCP 控制服务：监听 0.0.0.0:10010，每行一个 JSON 指令。
final class ControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "axtouch.control")
    private var buffer = Data()

    func start(port: UInt16 = 10010) {
        let params = NWParameters.tcp
        guard let portVal = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: portVal) else {
            print("[ControlServer] 监听失败 port=\(port)")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { conn in
            print("[ControlServer] 新连接:", conn.endpoint)
            conn.start(queue: self.queue)
            self.handle(conn)
        }
        listener.stateUpdateHandler = { state in
            print("[ControlServer] state: \(state)")
        }
        listener.start(queue: queue)
        print("[ControlServer] listening on 0.0.0.0:\(port)")
    }

    private func handle(_ conn: NWConnection) {
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    self.process(data: data, conn: conn)
                }
                if error == nil && !isComplete {
                    receive()
                } else {
                    conn.cancel()
                }
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
            let response = handleCommand(line)
            let out = (response + "\n").data(using: .utf8)!
            conn.send(content: out, completion: .contentProcessed { _ in })
        }
    }

    private func handleCommand(_ line: String) -> String {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            return #"{"ok":false,"error":"bad json"}"#
        }
        switch cmd {
        case "tap":
            let x = (obj["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (obj["y"] as? NSNumber)?.doubleValue ?? 0
            return jsonStr(AXBridge.shared.tap(x: CGFloat(x), y: CGFloat(y)))
        case "probe":
            return jsonStr(AXBridge.shared.probe())
        case "ping":
            return #"{"ok":true,"pong":true}"#
        default:
            return #"{"ok":false,"error":"unknown cmd"}"#
        }
    }

    private func jsonStr(_ obj: [String: Any]) -> String {
        let d = try? JSONSerialization.data(withJSONObject: obj)
        return String(data: d ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}

@main
struct AXTouchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var log: String = "TCP 服务已启动: 0.0.0.0:10010"

    var body: some View {
        VStack(spacing: 12) {
            Text("AX 触控 + TCP 控制").font(.title2).bold()
            Text("PC 连接: 手机IP:10010\n{\"cmd\":\"tap\",\"x\":196,\"y\":420}")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            ScrollView {
                Text(log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            .foregroundColor(.green)

            Button("手动点 (196,420)") {
                let r = AXBridge.shared.tap(x: 196, y: 420)
                log = String(describing: r)
            }
        }
        .padding()
        .onAppear {
            ControlServer().start(port: 10010)
        }
    }
}
