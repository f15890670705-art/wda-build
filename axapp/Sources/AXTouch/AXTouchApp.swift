import SwiftUI
import Foundation

/// AX 触控验证：探测 + 真实点击（CreateSystemWide → CopyElementAtPosition → PerformAction）
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
    func tap(x: CGFloat, y: CGFloat) -> String {
        load()
        guard let createSystemWide, let copyElementAtPosition, let performAction else {
            return "函数未就绪"
        }
        guard let sys = createSystemWide() else { return "CreateSystemWide 返回 nil" }
        var element: AnyObject?
        let err = copyElementAtPosition(sys, Float(x), Float(y), &element)
        guard err == 0, let el = element else {
            return "CopyElementAtPosition 失败 err=\(err)"
        }
        let pressErr = performAction(el, "AXPress" as CFString)
        return "PerformAction err=\(pressErr)"
    }

    @discardableResult
    func tapMany(x: CGFloat, y: CGFloat, times: Int) -> String {
        var results: [String] = []
        for i in 1...max(1, times) {
            let r = tap(x: x, y: y)
            results.append("[\(i)] \(r)")
            Thread.sleep(forTimeInterval: 0.4)
        }
        return results.joined(separator: "\n")
    }

    func probe() -> String {
        load()
        var out = [loadError]
        let syms = ["AXUIElementCreateSystemWide", "AXUIElementCopyElementAtPosition",
                    "AXUIElementPerformAction", "AXUIElementCopyAttributeValue", "AXUIElementGetPid"]
        if let h = handle {
            for s in syms {
                out.append("\(dlsym(h, s) != nil ? "✅" : "❌") \(s)")
            }
        }
        // ObjC 类探测
        for cls in ["XCUIDevice", "XCTRunnerDaemonSession"] {
            out.append("\(objc_getClass(cls) != nil ? "✅" : "❌") class \(cls)")
        }
        return out.joined(separator: "\n")
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
    @State private var log: String = ""
    @State private var xText = "196"
    @State private var yText = "420"

    var body: some View {
        VStack(spacing: 12) {
            Text("AX 触控验证").font(.title2).bold()

            HStack {
                TextField("x", text: $xText).textFieldStyle(.roundedBorder).frame(width: 80)
                TextField("y", text: $yText).textFieldStyle(.roundedBorder).frame(width: 80)
                Button("点 1 下") {
                    AXBridge.shared.load()
                    let x = Double(xText) ?? 196, y = Double(yText) ?? 420
                    log = AXBridge.shared.tap(x: CGFloat(x), y: CGFloat(y))
                }
                .buttonStyle(.borderedProminent)
                Button("连点 5 下") {
                    AXBridge.shared.load()
                    let x = Double(xText) ?? 196, y = Double(yText) ?? 420
                    log = AXBridge.shared.tapMany(x: CGFloat(x), y: CGFloat(y), times: 5)
                }
                .buttonStyle(.bordered)
            }

            Button("探测符号/类") {
                log = AXBridge.shared.probe()
            }

            ScrollView {
                Text(log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            .foregroundColor(.green)
        }
        .padding()
    }
}
