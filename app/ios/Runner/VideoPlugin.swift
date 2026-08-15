import AVFoundation
import Flutter
import UIKit

// The native half of the `checkin/video` channel: a lossless range trim and an MP4
// location read, the two clip operations no Flutter package covers. Registered from
// AppDelegate against the implicit engine's registrar, so it does not depend on the
// UIScene lifecycle wiring the rest of this app uses.
class VideoPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "checkin/video", binaryMessenger: registrar.messenger())
    let instance = VideoPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let path = args["path"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "missing path", details: nil))
      return
    }
    switch call.method {
    case "trim":
      let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
      let endMs = (args["endMs"] as? NSNumber)?.int64Value ?? 0
      trim(path: path, startMs: startMs, endMs: endMs, result: result)
    case "location":
      location(path: path, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // AVAssetExportSession with a passthrough preset copies the sample range without
  // re-encoding and carries the source track's preferredTransform (rotation) across, so a
  // portrait clip stays portrait.
  private func trim(path: String, startMs: Int64, endMs: Int64, result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard
      let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
    else {
      result(FlutterError(code: "export_init", message: "cannot create export session", details: nil))
      return
    }
    let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("trim_\(UInt64(Date().timeIntervalSince1970 * 1000)).mp4")
    let scale: Int32 = 1000
    let start = CMTime(value: startMs, timescale: scale)
    let end = CMTime(value: endMs, timescale: scale)
    export.outputURL = outURL
    export.outputFileType = .mp4
    export.timeRange = CMTimeRange(start: start, end: end)
    export.shouldOptimizeForNetworkUse = true
    export.exportAsynchronously {
      switch export.status {
      case .completed:
        result(outURL.path)
      default:
        let message = export.error?.localizedDescription ?? "export failed"
        result(FlutterError(code: "export_failed", message: message, details: nil))
      }
    }
  }

  // The clip's recording location lives in the common `.commonKeyLocation` metadata item as
  // an ISO6709 string (for example "+37.33+122.03/"). Absent for a clip that carries none.
  private func location(path: String, result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let items = AVMetadataItem.metadataItems(
      from: asset.metadata,
      withKey: AVMetadataKey.commonKeyLocation,
      keySpace: AVMetadataKeySpace.common)
    guard let raw = items.first?.stringValue, let coords = Self.parseISO6709(raw) else {
      result(nil)
      return
    }
    result(["lat": coords.lat, "lng": coords.lng])
  }

  // ISO6709 packs latitude then longitude as signed, sign-delimited decimals with an
  // optional trailing altitude and "/": "+DD.DDDD-DDD.DDDD/". Split on the sign that starts
  // the longitude (the second one), tolerating an optional leading sign on the latitude.
  static func parseISO6709(_ s: String) -> (lat: Double, lng: Double)? {
    let trimmed = s.hasSuffix("/") ? String(s.dropLast()) : s
    var numbers: [String] = []
    var current = ""
    for (i, ch) in trimmed.enumerated() {
      if (ch == "+" || ch == "-"), i != 0, !current.isEmpty {
        numbers.append(current)
        current = String(ch)
      } else {
        current.append(ch)
      }
    }
    if !current.isEmpty { numbers.append(current) }
    guard numbers.count >= 2, let lat = Double(numbers[0]), let lng = Double(numbers[1]) else {
      return nil
    }
    return (lat, lng)
  }
}
