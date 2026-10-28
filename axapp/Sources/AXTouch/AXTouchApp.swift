import SwiftUI
import Foundation

/// 复刻 AScript 的思路：
/// 1) dlopen 系统私有框架 AXRuntime + XCUIAutomation + XCTest
/// 2) 尝试 XCUIDevice → eventSynthesizer / XCTRunnerDaemonSession.shared
/// 3) 尝试 AXUIElement 系统级点击
/// 全部结果打在界面上，用于判定哪条路在 iOS 17.2.1 普通签名下可行。
final class AXBridge {
    static let shared = AXBridge()

    var logLines: [String] = []

    private func log(_ s: String) {
        logLines.append(s)
    }

    func probe() -> String {
        logLines.removeAll()
        log("== dlopen 私有框架 ==")

        let frameworks: [(String, String)] = [
            ("AXRuntime", "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime"),
            ("XCUIAutomation", "/System/Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation"),
            ("XCTestCore", "/System/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore"),
            ("XCTest(Developer路径)", "/Developer/Library/Frameworks/XCTest.framework/XCTest"),
            ("XCTest(系统Developer)", "/System/Developer/Library/Frameworks/XCTest.framework/XCTest"),
            ("UITesting(Private)", "/System/Library/PrivateFrameworks/UITesting.framework/UITesting"),
        ]
        var handles: [String: UnsafeMutableRawPointer] = [:]
        for (name, path) in frameworks {
            if let h = dlopen(path, RTLD_LAZY) {
                handles[name] = h
                log("✅ \(name): 成功")
            } else {
                log("❌ \(name): 失败")
            }
        }

        // ---- AXRuntime 符号探测 ----
        log("== AXRuntime 符号 ==")
        if let h = handles["AXRuntime"] {
            for sym in ["AXUIElementCreateSystemWide", "AXUIElementCopyElementAtPosition",
                        "AXUIElementPerformAction", "AXUIElementCreateApplication",
                        "AXUIElementCopyAttributeValue", "AXUIElementGetPid"] {
                let ok = dlsym(h, sym) != nil
                log("\(ok ? "✅" : "❌") \(sym)")
            }
        }

        // ---- XCUIAutomation 类探测（objc_getClass）----
        log("== XCUIAutomation/ObjC 类 ==")
        for cls in ["XCUIDevice", "XCTRunnerDaemonSession", "XCTestManagerConfiguration",
                    "XCTestSession", "XCUIApplicationImpl", "XCTestDriver",
                    "XCTAutomationSupportConfiguration", "XCSynthesizedEventRecord"] {
            let c = objc_getClass(cls)
            log("\(c != nil ? "✅" : "❌") class \(cls)")
        }

        // ---- 尝试通过 ObjC runtime 调 XCUIDevice.shared → eventSynthesizer ----
        log("== XCUIDevice 事件合成器 ==")
        if let cls = objc_getClass("XCUIDevice") {
            let dev = (cls as AnyObject).perform(NSSelectorFromString("sharedDevice"))?.takeRetainedValue()
            if let dev = dev {
                log("✅ XCUIDevice.sharedDevice: \(dev)")
                let es = dev.perform(NSSelectorFromString("eventSynthesizer"))?.takeUnretainedValue()
                if let es = es {
                    log("✅ eventSynthesizer: \(es)")
                    let sel_press = NSSelectorFromString("pressAtPoint:radius:orientation:touchNumber:")
                    if es.responds(to: sel_press) {
                        log("✅ eventSynthesizer 响应 pressAtPoint:radius:orientation:touchNumber:")
                    } else {
                        log("❌ eventSynthesizer 无 pressAtPoint 方法")
                    }
                } else {
                    log("❌ eventSynthesizer 为 nil（可能需要 daemon 会话）")
                }
            } else {
                log("❌ sharedDevice 为 nil")
            }
        } else {
            log("❌ XCUIDevice 类不存在")
        }

        log("== XCTRunnerDaemonSession 类 ==")
        if let cls = objc_getClass("XCTRunnerDaemonSession") {
            log("类存在: \(cls)")
        }

        return logLines.joined(separator: "\n")
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
    @State private var log: String = "点按钮开始探测"

    var body: some View {
        VStack(spacing: 12) {
            Text("AX/XCUI 可行性探测").font(.title2).bold()
            ScrollView {
                Text(log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            .foregroundColor(.green)

            Button("开始探测") {
                log = AXBridge.shared.probe()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
