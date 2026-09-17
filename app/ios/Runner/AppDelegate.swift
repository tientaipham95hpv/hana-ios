import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    clearPrivateRuntime()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "HanaNativeBridge"
    ) else { return }
    HanaNativeBridge.register(with: registrar)
  }

  private func clearPrivateRuntime() {
    guard let caches = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first else { return }
    try? FileManager.default.removeItem(
      at: caches.appendingPathComponent("prv_rt", isDirectory: true)
    )
  }
}

private final class HanaNativeBridge: NSObject, AVSpeechSynthesizerDelegate {
  private static var shared: HanaNativeBridge?
  private let ttsChannel: FlutterMethodChannel
  private let recorderChannel: FlutterMethodChannel
  private let secureChannel: FlutterMethodChannel
  private let synthesizer = AVSpeechSynthesizer()
  private let audioSession = AVAudioSession.sharedInstance()
  private var utteranceIds: [ObjectIdentifier: String] = [:]
  private var recorder: AVAudioRecorder?
  private var recordingURL: URL?
  private var recordingStartedAt: TimeInterval = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    shared = HanaNativeBridge(messenger: registrar.messenger())
  }

  private init(messenger: FlutterBinaryMessenger) {
    ttsChannel = FlutterMethodChannel(
      name: "hana/native_tts",
      binaryMessenger: messenger
    )
    recorderChannel = FlutterMethodChannel(
      name: "hana/voice_recorder",
      binaryMessenger: messenger
    )
    secureChannel = FlutterMethodChannel(
      name: "hana/secure_window",
      binaryMessenger: messenger
    )
    super.init()
    synthesizer.delegate = self
    ttsChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleTts(call, result: result)
    }
    recorderChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleRecorder(call, result: result)
    }
    secureChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleSecureWindow(call, result: result)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(audioSessionInterrupted(_:)),
      name: AVAudioSession.interruptionNotification,
      object: audioSession
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(audioRouteChanged(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: audioSession
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func handleTts(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      result(nil)
    case "listVoices":
      let voices = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.lowercased().hasPrefix("vi") }
        .sorted {
          $0.name == $1.name
            ? $0.identifier < $1.identifier
            : $0.name < $1.name
        }
        .map { voice in
          [
            "name": voice.name,
            "identifier": voice.identifier,
            "locale": voice.language,
            "quality": qualityName(voice.quality),
          ]
        }
      result(voices)
    case "speak":
      guard recorder == nil else {
        result(FlutterError(
          code: "AUDIO_BUSY",
          message: "Cannot speak while recording",
          details: nil
        ))
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let utteranceId = arguments["utteranceId"] as? String,
        let text = arguments["text"] as? String,
        !utteranceId.isEmpty,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        result(FlutterError(
          code: "TTS_INVALID",
          message: "Invalid speech request",
          details: nil
        ))
        return
      }
      do {
        try configureAudioForSpeech()
        if synthesizer.isSpeaking || synthesizer.isPaused {
          synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        let selectedIdentifier = arguments["voiceIdentifier"] as? String
        if let selectedIdentifier, !selectedIdentifier.isEmpty {
          guard
            let voice = AVSpeechSynthesisVoice(identifier: selectedIdentifier),
            voice.language.lowercased().hasPrefix("vi")
          else {
            deactivateAudioSession()
            result(FlutterError(
              code: "TTS_VOICE_UNAVAILABLE",
              message: "Selected Vietnamese voice is unavailable",
              details: nil
            ))
            return
          }
          utterance.voice = voice
        } else {
          utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
        }
        utterance.rate = clampedFloat(
          arguments["rate"], minimum: 0.1, maximum: 0.65, fallback: 0.5
        )
        utterance.pitchMultiplier = clampedFloat(
          arguments["pitch"], minimum: 0.5, maximum: 2, fallback: 1
        )
        utterance.volume = clampedFloat(
          arguments["volume"], minimum: 0, maximum: 1, fallback: 1
        )
        utteranceIds[ObjectIdentifier(utterance)] = utteranceId
        synthesizer.speak(utterance)
        result(nil)
      } catch {
        result(FlutterError(
          code: "TTS_AUDIO_SESSION",
          message: String(describing: error),
          details: nil
        ))
      }
    case "stop":
      if synthesizer.isSpeaking || synthesizer.isPaused {
        synthesizer.stopSpeaking(at: .immediate)
      } else {
        deactivateAudioSession()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleRecorder(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "permissionStatus":
      result(permissionName(audioSession.recordPermission))
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
    case "start":
      guard
        let arguments = call.arguments as? [String: Any],
        let clientId = arguments["clientId"] as? String,
        UUID(uuidString: clientId) != nil
      else {
        result(FlutterError(
          code: "AUDIO_INVALID",
          message: "Invalid client id",
          details: nil
        ))
        return
      }
      requestRecordPermission { [weak self] granted in
        guard let self else { return }
        guard granted else {
          result(false)
          return
        }
        self.startRecording(clientId: clientId, result: result)
      }
    case "stop":
      stopRecording(result: result)
    case "cancel":
      cancelRecording(deleteFile: true, notifyFlutter: false)
      result(nil)
    case "delete":
      if
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String
      {
        deleteVoiceFile(path)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleSecureWindow(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "setSecure":
      // iOS has no FLAG_SECURE equivalent. Lifecycle privacy overlays remain;
      // production-private mode stays disabled until Phase 10.
      result(nil)
    case "clearPrivateRuntime":
      guard let caches = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first else {
        result(nil)
        return
      }
      try? FileManager.default.removeItem(
        at: caches.appendingPathComponent("prv_rt", isDirectory: true)
      )
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
    switch audioSession.recordPermission {
    case .granted:
      completion(true)
    case .denied:
      completion(false)
    case .undetermined:
      audioSession.requestRecordPermission { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    @unknown default:
      completion(false)
    }
  }

  private func startRecording(clientId: String, result: @escaping FlutterResult) {
    guard recorder == nil else {
      result(FlutterError(
        code: "AUDIO_BUSY",
        message: "Recording already active",
        details: nil
      ))
      return
    }
    if synthesizer.isSpeaking || synthesizer.isPaused {
      synthesizer.stopSpeaking(at: .immediate)
    }
    do {
      try audioSession.setCategory(
        .playAndRecord,
        mode: .measurement,
        options: [.defaultToSpeaker, .allowBluetooth]
      )
      try audioSession.setActive(true)
      let directory = try voiceDirectory()
      let url = directory.appendingPathComponent("\(clientId).m4a")
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 48_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
      let next = try AVAudioRecorder(url: url, settings: settings)
      guard next.prepareToRecord(), next.record() else {
        throw NSError(domain: "HanaAudio", code: 1)
      }
      recorder = next
      recordingURL = url
      recordingStartedAt = ProcessInfo.processInfo.systemUptime
      result(true)
    } catch {
      cancelRecording(deleteFile: true, notifyFlutter: false)
      result(FlutterError(
        code: "AUDIO_START_FAILED",
        message: String(describing: error),
        details: nil
      ))
    }
  }

  private func stopRecording(result: @escaping FlutterResult) {
    guard let active = recorder, let url = recordingURL else {
      result(nil)
      return
    }
    let duration = max(
      0,
      Int((ProcessInfo.processInfo.systemUptime - recordingStartedAt) * 1_000)
    )
    active.stop()
    recorder = nil
    recordingURL = nil
    deactivateAudioSession()
    result(["path": url.path, "durationMs": duration])
  }

  private func cancelRecording(deleteFile: Bool, notifyFlutter: Bool) {
    let url = recordingURL
    recorder?.stop()
    recorder = nil
    recordingURL = nil
    if deleteFile, let url { try? FileManager.default.removeItem(at: url) }
    deactivateAudioSession()
    if notifyFlutter {
      recorderChannel.invokeMethod("recordingInterrupted", arguments: nil)
    }
  }

  private func deleteVoiceFile(_ path: String) {
    guard let directory = try? voiceDirectory() else { return }
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    guard candidate.deletingLastPathComponent() == directory.standardizedFileURL else { return }
    try? FileManager.default.removeItem(at: candidate)
  }

  private func voiceDirectory() throws -> URL {
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let directory = root.appendingPathComponent("voice", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return directory
  }

  private func configureAudioForSpeech() throws {
    try audioSession.setCategory(
      .playAndRecord,
      mode: .spokenAudio,
      options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers]
    )
    try audioSession.setActive(true)
  }

  private func deactivateAudioSession() {
    try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
  }

  @objc private func audioSessionInterrupted(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: raw) == .began
    else { return }
    cancelRecording(deleteFile: true, notifyFlutter: true)
    if synthesizer.isSpeaking || synthesizer.isPaused {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  @objc private func audioRouteChanged(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
    else { return }
    cancelRecording(deleteFile: true, notifyFlutter: true)
    if synthesizer.isSpeaking || synthesizer.isPaused {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  @objc private func applicationDidEnterBackground() {
    cancelRecording(deleteFile: true, notifyFlutter: true)
    if synthesizer.isSpeaking || synthesizer.isPaused {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didStart utterance: AVSpeechUtterance
  ) {
    emitSpeechEvent("speechStarted", utterance: utterance)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    emitSpeechEvent("speechFinished", utterance: utterance, terminal: true)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    emitSpeechEvent("speechCancelled", utterance: utterance, terminal: true)
  }

  private func emitSpeechEvent(
    _ method: String,
    utterance: AVSpeechUtterance,
    terminal: Bool = false
  ) {
    let key = ObjectIdentifier(utterance)
    guard let utteranceId = utteranceIds[key] else { return }
    if terminal {
      utteranceIds.removeValue(forKey: key)
      if utteranceIds.isEmpty {
        deactivateAudioSession()
      }
    }
    ttsChannel.invokeMethod(method, arguments: ["utteranceId": utteranceId])
  }

  private func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
    if quality == .enhanced { return "enhanced" }
    return quality.rawValue > AVSpeechSynthesisVoiceQuality.enhanced.rawValue
      ? "premium"
      : "default"
  }

  private func permissionName(_ permission: AVAudioSession.RecordPermission) -> String {
    switch permission {
    case .undetermined: return "notDetermined"
    case .granted: return "granted"
    case .denied: return "denied"
    @unknown default: return "restricted"
    }
  }

  private func clampedFloat(
    _ value: Any?,
    minimum: Float,
    maximum: Float,
    fallback: Float
  ) -> Float {
    guard let number = value as? NSNumber else { return fallback }
    return min(max(number.floatValue, minimum), maximum)
  }
}
