import AVFoundation
import Foundation

/// Vant must never send mirrored video. WebRTC's `RTCCameraVideoCapturer`
/// (inside the flutter_webrtc plugin, in a binary framework) never touches
/// `AVCaptureConnection.isVideoMirrored`, so iOS applies its default: front
/// camera connections are auto-mirrored and the mirrored frames are what get
/// encoded and sent — remote peers see text backwards.
///
/// We can't reach the capturer's connection from app code, so instead we
/// force every connection on every capture session to unmirrored:
///  - `commitConfiguration` is swizzled so any session rebuild (initial
///    capture, front/rear switch, format change) is immediately un-mirrored
///    right after the new connections are created.
///  - `didStartRunning` is observed as a safety net for connections created
///    outside a commit (shouldn't happen, but idempotent and cheap).
///
/// `videoMirrored = false` is a no-op for the rear camera (iOS never mirrors
/// it anyway) and does not affect the local preview: self-view mirroring is
/// applied display-side by `LocalCallVideoView` (mirror = front camera only).
@objcMembers
final class CaptureSessionMirrorGuard: NSObject {
    private static var installed = false
    private static var observer: NSObjectProtocol?

    /// Call once at launch. Safe to call more than once.
    static func install() {
        guard !installed else { return }
        installed = true

        let original = class_getInstanceMethod(
            AVCaptureSession.self,
            #selector(AVCaptureSession.commitConfiguration)
        )
        let swizzled = class_getInstanceMethod(
            AVCaptureSession.self,
            #selector(AVCaptureSession.vant_commitConfiguration)
        )
        if let original = original, let swizzled = swizzled {
            method_exchangeImplementations(original, swizzled)
        }

        observer = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStartRunning,
            object: nil,
            queue: .main
        ) { note in
            (note.object as? AVCaptureSession)?.vant_unmirrorConnections()
        }
    }
}

extension AVCaptureSession {
    @objc func vant_commitConfiguration() {
        // Swizzled: this call invokes the original commitConfiguration.
        vant_commitConfiguration()
        vant_unmirrorConnections()
    }

    func vant_unmirrorConnections() {
        for output in outputs {
            for connection in output.connections {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyConfiguresVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
        }
    }
}
