// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Phase 4 pre-flight dummy. This extension intentionally does nothing: it
/// exists so a test IPA can prove whether the installer's re-signing keeps
/// PlugIns/WindowsiOSJITHelper.appex inside the app bundle. The real JIT
/// helper replaces this file during the Phase 4 port.
@objc(WindowsiOSJITHelperHandler)
final class WindowsiOSJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: [], completionHandler: nil)
    }
}
