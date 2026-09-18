import AVFoundation
import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {
  func testSpeechSynthesizerInitializesIdle() {
    let synthesizer = AVSpeechSynthesizer()
    XCTAssertFalse(synthesizer.isSpeaking)
    XCTAssertFalse(synthesizer.isPaused)
  }

  func testVietnameseVoiceEnumerationMetadataIsCanonical() {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter {
      $0.language.lowercased().hasPrefix("vi")
    }
    if voices.isEmpty {
      print("VOICE_RUNTIME_VALIDATION_PENDING: no vi-VN voice asset on CI runtime")
    } else {
      print("Vietnamese voice metadata validated for \(voices.count) installed voice(s)")
    }
    for voice in voices {
      XCTAssertFalse(voice.name.isEmpty)
      XCTAssertFalse(voice.identifier.isEmpty)
      XCTAssertTrue(voice.language.lowercased().hasPrefix("vi"))
    }
  }

  func testMicrophoneUsageDescriptionIsPresent() {
    let description = Bundle.main.object(
      forInfoDictionaryKey: "NSMicrophoneUsageDescription"
    ) as? String
    XCTAssertFalse(description?.isEmpty ?? true)
  }
}
