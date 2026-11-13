import AVFoundation
import AVKit
import CoreMedia
import Flutter
import UIKit
import WebRTC
import flutter_webrtc

/// Host view backed by AVSampleBufferDisplayLayer — the PiP window renders
/// whatever CMSampleBuffers are enqueued on this layer.
final class VantSampleBufferView: UIView {
  override class var layerClass: AnyClass {
    return AVSampleBufferDisplayLayer.self
  }

  var videoLayer: AVSampleBufferDisplayLayer {
    return layer as! AVSampleBufferDisplayLayer
  }
}

/// RTCVideoRenderer sink attached to the remote video track: converts each
/// RTCVideoFrame to a CMSampleBuffer and enqueues it on the display layer.
/// Mirrors flutter_webrtc's own platform-view rendering path.
final class VantPipFrameSink: NSObject, RTCVideoRenderer {
  weak var targetLayer: AVSampleBufferDisplayLayer?

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame = frame, let layer = targetLayer else { return }
    guard let pb = toCVPixelBuffer(frame: frame) else { return }

    var formatDesc: CMVideoFormatDescription?
    var status = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      formatDescriptionOut: &formatDesc
    )
    guard status == noErr, let desc = formatDesc else { return }

    var timing = CMSampleTimingInfo.invalid
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      formatDescription: desc,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sb = sampleBuffer else { return }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, true),
       CFArrayGetCount(attachments) > 0 {
      let dict = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: NSMutableDictionary.self
      )
      dict[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
    }

    if layer.status == .failed {
      layer.flush()
    }
    if #available(iOS 14.0, *) {
      if layer.requiresFlushToResumeDecoding {
        layer.flushAndRemoveImage()
      }
    }
    layer.enqueue(sb)
  }

  /// Any RTCVideoFrame -> CVPixelBuffer (NV12). Same recipe flutter_webrtc's
  /// FlutterRTCVideoRenderer uses: toI420, rotate the I420 planes when the
  /// frame carries a rotation (PiP renders the enqueued buffers directly —
  /// a layer transform would be ignored), then I420ToNV12.
  private func toCVPixelBuffer(frame: RTCVideoFrame) -> CVPixelBuffer? {
    var i420 = frame.buffer.toI420()
    if frame.rotation != ._0 {
      i420 = rotate(i420, rotation: frame.rotation)
    }
    guard let src = i420 else { return nil }

    var output: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let result = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(src.width),
      Int(src.height),
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      attrs,
      &output
    )
    guard result == kCVReturnSuccess, let pb = output else { return nil }

    CVPixelBufferLockBaseAddress(pb, [])
    guard let dstY = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
          let dstUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
      CVPixelBufferUnlockBaseAddress(pb, 0)
      return nil
    }
    let dstYStride = Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
    let dstUVStride = Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1))

    RTCYUVHelper.i420(
      toNV12: src.dataY,
      srcStrideY: src.strideY,
      srcU: src.dataU,
      srcStrideU: src.strideU,
      srcV: src.dataV,
      srcStrideV: src.strideV,
      dstY: dstY,
      dstStrideY: dstYStride,
      dstUV: dstUV,
      dstStrideUV: dstUVStride,
      width: src.width,
      height: src.height
    )
    CVPixelBufferUnlockBaseAddress(pb, 0)
    return pb
  }

  /// Mirrors FlutterRTCVideoRenderer's correctRotation:withRotation: —
  /// I420Rotate into a fresh buffer whose width/height are swapped for
  /// quarter turns.
  private func rotate(_ src: RTCI420Buffer, rotation: RTCVideoRotation) -> RTCI420Buffer {
    var width = src.width
    var height = src.height
    if rotation == ._90 || rotation == ._270 {
      swap(&width, &height)
    }
    let dst = RTCI420Buffer(width: width, height: height)
    RTCYUVHelper.i420Rotate(
      src.dataY,
      srcStrideY: src.strideY,
      srcU: src.dataU,
      srcStrideU: src.strideU,
      srcV: src.dataV,
      srcStrideV: src.strideV,
      dstY: dst.dataY,
      dstStrideY: dst.strideY,
      dstU: dst.dataU,
      dstStrideU: dst.strideU,
      dstV: dst.dataV,
      dstStrideV: dst.strideV,
      width: src.width,
      height: src.height,
      mode: rotation
    )
    return dst
  }
}

/// iOS video-call Picture-in-Picture manager (ff_pip_ios).
///
/// Apple's AVPictureInPictureController can't take an RTCVideoRenderer view —
/// it needs an AVSampleBufferDisplayLayer fed with CMSampleBuffers, so this
/// manager attaches a frame sink to the remote RTCVideoTrack (resolved via
/// flutter_webrtc's shared plugin instance) and pipes decoded frames into the
/// layer. With `canStartPictureInPictureAutomaticallyFromInline` the system
/// auto-enters PiP when the app backgrounds mid-video-call; delegate events
/// report state back to Dart as pipChanged/pipOutcome on the call channel.
final class IosCallPipManager: NSObject {
  private weak var channel: FlutterMethodChannel?
  private let frameSink = VantPipFrameSink()

  private var pipController: AVPictureInPictureController?
  private var hostView: VantSampleBufferView?
  private weak var attachedTrack: RTCVideoTrack?
  private var pendingTrackId: String?
  private var pipEligible = false
  private var restoreRequested = false
  private var backgroundObserver: NSObjectProtocol?

  private(set) var isInPip = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.onDidEnterBackground()
    }
  }

  deinit {
    if let observer = backgroundObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - Dart-facing surface (mirrors MainActivity's setPipParams etc.)

  func setPipParams(enabled: Bool, trackId: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.pipEligible = enabled
      if let trackId = trackId, !trackId.isEmpty {
        self.pendingTrackId = trackId
      }
      if enabled {
        self.ensurePipSetup()
        if let trackId = trackId, !trackId.isEmpty {
          self.attachToTrack(trackId)
        }
      } else {
        self.teardown()
      }
    }
  }

  /// Call ended: detach, close any open PiP window, drop the controller.
  func callEnded() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.pipEligible = false
      self.teardown()
    }
  }

  /// Dart asked to close the PiP window (X-dismiss handled on our side too).
  func exitPipIfActive() {
    DispatchQueue.main.async { [weak self] in
      if self?.pipController?.isPictureInPictureActive == true {
        self?.pipController?.stopPictureInPicture()
      }
    }
  }

  // MARK: - Setup / teardown

  private func ensurePipSetup() {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      NSLog("VantPip: PiP not supported on this device")
      return
    }
    if hostView == nil {
      // The display layer must live in the window hierarchy for the PiP
      // content source — a hidden 1pt view on the key window is enough.
      let view = VantSampleBufferView(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
      view.videoLayer.videoGravity = .resizeAspectFill
      hostWindow()?.addSubview(view)
      hostView = view
      frameSink.targetLayer = view.videoLayer
    }
    if pipController == nil {
      let layer = hostView!.videoLayer
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: layer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = true
      pipController = controller
      NSLog("VantPip: controller ready")
    }
  }

  private func hostWindow() -> UIWindow? {
    // Single-scene app (AppDelegate.window) — scene-aware lookup with a
    // legacy fallback so a future scene migration doesn't silently break.
    for scene in UIApplication.shared.connectedScenes {
      if let windowScene = scene as? UIWindowScene,
         scene.activationState == .foregroundActive,
         let window = windowScene.windows.first {
        return window
      }
    }
    return UIApplication.shared.delegate?.window ?? nil
  }

  private func attachToTrack(_ trackId: String) {
    guard let track = findRemoteVideoTrack(trackId) else {
      NSLog("VantPip: remote track %@ not found yet", trackId)
      return
    }
    if attachedTrack === track { return }
    detachTrack()
    track.addRenderer(frameSink)
    attachedTrack = track
    NSLog("VantPip: frame sink attached to remote track %@", trackId)
  }

  private func detachTrack() {
    attachedTrack?.removeRenderer(frameSink)
    attachedTrack = nil
  }

  /// Resolve the remote RTCVideoTrack through flutter_webrtc's shared
  /// plugin — its peerConnections map holds transceivers whose receivers
  /// own the remote tracks.
  private func findRemoteVideoTrack(_ trackId: String) -> RTCVideoTrack? {
    guard let plugin = FlutterWebRTCPlugin.sharedSingleton(),
          let pcs = plugin.peerConnections as? [String: RTCPeerConnection] else {
      return nil
    }
    for pc in pcs.values {
      for transceiver in pc.transceivers {
        if let track = transceiver.receiver.track as? RTCVideoTrack,
           track.trackId == trackId {
          return track
        }
      }
    }
    return nil
  }

  private func teardown() {
    detachTrack()
    pendingTrackId = nil
    if pipController?.isPictureInPictureActive == true {
      pipController?.stopPictureInPicture()
    }
    pipController?.delegate = nil
    pipController = nil
    frameSink.targetLayer = nil
    hostView?.removeFromSuperview()
    hostView = nil
    if isInPip {
      isInPip = false
      reportPipChanged(false)
    }
  }

  // MARK: - Auto-enter on background

  private func onDidEnterBackground() {
    guard pipEligible,
          let controller = pipController,
          controller.isPictureInPicturePossible,
          !controller.isPictureInPictureActive else { return }
    NSLog("VantPip: backgrounded with eligible call -> startPictureInPicture")
    controller.startPictureInPicture()
  }

  // MARK: - Dart reporting

  private func reportPipChanged(_ inPip: Bool) {
    channel?.invokeMethod("pipChanged", arguments: ["isPip": inPip])
  }

  private func reportPipOutcome(_ outcome: String) {
    channel?.invokeMethod("pipOutcome", arguments: ["outcome": outcome])
  }
}

// MARK: - AVPictureInPictureController delegates

extension IosCallPipManager: AVPictureInPictureControllerDelegate,
                              AVPictureInPictureSampleBufferPlaybackDelegate {

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("VantPip: will start")
    restoreRequested = false
    isInPip = true
    reportPipChanged(true)
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("VantPip: did start")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("VantPip: failed to start: %@", error.localizedDescription)
    isInPip = false
    reportPipChanged(false)
  }

  func pictureInPictureControllerWillStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("VantPip: will stop (restore=%@)", restoreRequested ? "yes" : "no")
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("VantPip: did stop (restore=%@)", restoreRequested ? "yes" : "no")
    isInPip = false
    reportPipChanged(false)
    // Same expand-vs-dismiss classification Android emits natively:
    // tapping the PiP window asks to restore UI (= expanded); the system
    // close affordance stops PiP without a restore request (= dismissed).
    reportPipOutcome(restoreRequested ? "expanded" : "dismissed")
    restoreRequested = false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void
  ) {
    NSLog("VantPip: restore UI requested (expand)")
    restoreRequested = true
    completionHandler(true)
  }

  // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    shouldTransitionTo newSize: CGSize
  ) {
    // Accept any system-proposed PiP size; the sample layer scales itself.
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    // A live call has no pause affordance — remote frames keep streaming.
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    // Indefinite live stream: hide the playback scrubber.
    return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    return false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didSkipToInterval interval: TimeInterval
  ) {
    // No seeking in a live call.
  }
}
