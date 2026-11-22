// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import UIKit

/// `csops(2)`. Reading CS_DEBUGGED is how we ask "is a debugger attached right
/// now" without executing anything — unlike the brk probe, which costs a trap.
@_silgen_name("csops")
private func csops(_ pid: Int32, _ ops: Int32,
                   _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

private let CS_OPS_STATUS = Int32(0)
private let CS_DEBUGGED = UInt32(0x10000000)

/// The small surface JITCoordinator and JITSetupView ask of the claim layer.
///
/// Adapted from Henge's JITBootstrap, but not its state machine: Henge's C API
/// (henge_ios_jit_*) is fine-grained (prewarm / prewarm-self / self-route /
/// detach / a MAP_JIT probe), while this fork's winios_jit.h gathers the claim
/// into `winios_jit_acquire(bytes, detach_after)`, already driven by
/// `WinIOSBridge.tryAcquireJIT` — the path the StikDebug hand-off has used all
/// along. So this file only answers questions (is a debugger on? is the region
/// live? what is installed?) and performs the two URL hand-offs; the claim
/// itself stays with the bridge, and SessionView calls it when
/// JITCoordinator's attachGeneration moves.
enum JITBootstrap {
    /// True once the JIT region is held and live — the bridge's TXM JIT state.
    static var ready: Bool { WinIOSBridge.shared.isJITLive }

    /// Whether a debugger marks this process right now (CS_DEBUGGED), without
    /// the log line, for polling while the built-in helper attaches.
    static var debuggedFlag: Bool {
        (csStatus() ?? 0) & CS_DEBUGGED != 0
    }

    private static func csStatus() -> UInt32? {
        var flags: UInt32 = 0
        let rc = withUnsafeMutableBytes(of: &flags) { buf in
            csops(getpid(), CS_OPS_STATUS, buf.baseAddress, buf.count)
        }
        return rc == 0 ? flags : nil
    }

    /// Windows 11's built-in helper (StikJIT's script, which answers the detach
    /// brk) was started this launch.
    nonisolated(unsafe) static var helperMayBeAttached = false

    static var isStikDebugInstalled: Bool {
        URL(string: "stikjit://").map(UIApplication.shared.canOpenURL) ?? false
    }

    /// Whether TrollStore is on this device. It answers enable-jit on the `apple-magnifier` scheme, but that scheme is also the
    /// Magnifier app's, on every iPhone, so whether it opens says nothing. A Windows 11 TrollStore installed knows from its marker file;
    /// otherwise SpringBoard is asked to open TrollStore, suspended, which an ordinary app is refused (9) when it exists and told
    /// it does not (7) when it does not. TrollStore installs on iOS 14.0 to 17.0 only.
    static let isTrollStoreInstalled: Bool = {
        if isInstalledWithTrollStore { return true }
        if #available(iOS 17.0.1, *) { return false }
        typealias Launch = @convention(c) (NSString, NSURL?, NSDictionary?, NSDictionary?, Bool) -> Int32
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW),
              let sym = dlsym(lib, "SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions") else { return false }
        let launch = unsafeBitCast(sym, to: Launch.self)
        for id in ["com.opa334.TrollStore", "com.opa334.TrollStoreLite"] {
            let r = launch(id as NSString, nil, nil, nil, true)
            WinIOSLog.log("jit", "SpringBoard on opening \(id): \(r)")
            if r == 9 { return true }
        }
        return false
    }()

    /// Whether this copy of Windows 11 was installed by TrollStore (or TrollStore Lite): it leaves a marker file next to the app in
    /// its bundle container (TrollStore's `TS_MARKER`).
    static var isInstalledWithTrollStore: Bool {
        let container = Bundle.main.bundleURL.deletingLastPathComponent()
        return ["_TrollStore", "_TrollStoreLite"].contains {
            FileManager.default.fileExists(atPath: container.appendingPathComponent($0).path)
        }
    }

    /// A rootless jailbreak (Dopamine and its kin) puts its files in /var/jb and lets apps see it.
    static var isJailbroken: Bool { FileManager.default.fileExists(atPath: "/var/jb") }

    /// Whether Windows 11 was already marked as debugged when it was opened, before it asked anything of anyone. That is what a
    /// jailbreak that allows JIT in apps does to every app it launches (Dopamine's "Allow JIT in Apps" setting), and it needs
    /// no hand-off at all. Read once, early (VMViewModel.init), so a later attach is not mistaken for it.
    nonisolated(unsafe) static var debuggedAtLaunch = false
    static func noteLaunchState() { debuggedAtLaunch = (csStatus() ?? 0) & CS_DEBUGGED != 0 }

    /// henge-jit.js as standard base64, which Built-in StikJIT's custom script takes.
    static var scriptBase64: String? {
        loadScript()?.data(using: .utf8)?.base64EncodedString()
    }

    /// Ask StikDebug to attach to us and run the JIT script.
    ///
    /// This backgrounds Windows 11 — iOS switches to StikDebug, which attaches over the
    /// debugserver protocol, runs the script, and relaunches us. Everything after
    /// this point happens in a *new* foreground pass of the app.
    @MainActor
    static func requestTrollStoreAttach() -> Bool {
        WinIOSLog.log("jit", "requestTrollStoreAttach() -- handing off to TrollStore")
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }

        let url = "apple-magnifier://enable-jit?bundle-id=\(bundleID)"
        guard isTrollStoreInstalled, let launchURL = URL(string: url) else {
            WinIOSLog.log("jit", "FAIL: TrollStore is not installed")
            return false
        }

        WinIOSLog.log("jit", "opening apple-magnifier:// for bundle \(bundleID)")
        UIApplication.shared.open(launchURL)
        return true
    }

    @MainActor
    static func requestAttach() -> Bool {
        WinIOSLog.log("jit", "requestAttach() -- handing off to StikDebug")

        guard let bundleID = Bundle.main.bundleIdentifier else {
            WinIOSLog.log("jit", "FAIL: no bundle identifier")
            return false
        }

        // pid, not just bundle-id: StikDebug's bundle-id path launches that id via installd.
        // A LiveContainer guest has no such record; only the container is installed. The pid
        // path attaches to this already-running process. bundle-id stays as the fallback.
        var url = "stikjit://enable-jit?bundle-id=\(bundleID)&pid=\(getpid())"

        // Sending the script inline makes Windows 11 self-contained. StikDebug accepts
        // script-data unconditionally (HomeView.handleExternalURL), so we do not
        // depend on the user having assigned a script to Windows 11 in StikDebug's UI.
        if let script = loadScript(), let encoded = base64URLEncode(script) {
            WinIOSLog.log("jit", "loaded henge-jit.js (\(script.count) chars, "
                             + "\(encoded.count) chars encoded); sending inline")
            url += "&script-data=\(encoded)"
        } else {
            WinIOSLog.log("jit", "WARNING: could not load henge-jit.js from the bundle. "
                             + "Falling back to whatever script StikDebug has assigned "
                             + "to this bundle id -- if none, JIT will not be enabled.")
        }

        guard let launchURL = URL(string: url) else {
            WinIOSLog.log("jit", "FAIL: malformed StikDebug URL (\(url.count) chars)")
            return false
        }

        // Not canOpenURL first: that needs LSApplicationQueriesSchemes for 'stikjit', which is
        // checked against whichever app iOS actually installed — a container app hosting Windows 11
        // fails the query even when StikDebug is installed. open() has no such restriction.
        WinIOSLog.log("jit", "opening stikjit:// for bundle \(bundleID), pid \(getpid()); "
                         + "Windows 11 will be backgrounded and relaunched after attach")
        UIApplication.shared.open(launchURL, options: [:]) { success in
            if !success {
                WinIOSLog.log("jit", "FAIL: open(stikjit://) did not succeed -- StikDebug is not installed")
            }
        }
        return true
    }

    private static func loadScript() -> String? {
        // Accept either bundle layout: the build copies henge-jit.js to the bundle
        // root, but a folder-reference build phase would put it under Resources/.
        let candidates = [
            Bundle.main.path(forResource: "henge-jit", ofType: "js"),
            Bundle.main.path(forResource: "henge-jit", ofType: "js", inDirectory: "Resources"),
        ]
        for case let path? in candidates {
            if let s = try? String(contentsOfFile: path, encoding: .utf8) { return s }
        }
        return nil
    }

    /// StikDebug expects base64url (`-`/`_`, no padding) and percent-encodes it
    /// into the query string.
    private static func base64URLEncode(_ s: String) -> String? {
        guard let data = s.data(using: .utf8) else { return nil }
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return b64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}
