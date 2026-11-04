import Foundation

#if BEX_UI_TEST_ARTIFACT && !DEBUG
  #error("BEX_UI_TEST_ARTIFACT requires DEBUG fixture sources; do not build it as Release.")
#endif

/// Compile-time identity is the authority. Bundle metadata is a consistency check,
/// not a signature or an OS sandbox. Runtime selectors can never grant test identity.
enum AppLaunchMode: Equatable {
  case production
  case isolatedUITesting
  case manualSystemTargetTesting
  case rejectedUITesting

  static let artifactBundleIdentifier = "com.bex.desktop.ui-validation"
  static let artifactMarkerKey = "BexUITestArtifact"
  static let artifactMarkerValue = "isolated-ui-v1"

  static var isDebugBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  static var isUITestArtifactBuild: Bool {
    #if BEX_UI_TEST_ARTIFACT
      true
    #else
      false
    #endif
  }

  #if BEX_UI_TEST_ARTIFACT
    // Present only in the compiled test branch and observable through the inert
    // pre-AppKit probe. A build verifier also checks this without executing it.
    static let compiledArtifactStamp = "BEX_COMPILED_UI_TEST_ARTIFACT_V1_7A8D4C62"
  #endif

  static func resolve(
    arguments: [String], environment: [String: String],
    debugBuild: Bool = isDebugBuild,
    artifactBuild: Bool = isUITestArtifactBuild,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    artifactMarker: Any? = Bundle.main.object(forInfoDictionaryKey: artifactMarkerKey)
  ) -> Self {
    let testArguments = arguments.filter {
      $0.hasPrefix("--ui-testing") || $0 == "--missing-credential"
        || $0 == "--open-fix-and-send" || $0 == "--bex-ui-artifact-probe"
    }
    let requested = !testArguments.isEmpty
      || environment.keys.contains { $0 == "BEX_UI_TESTING" || $0.hasPrefix("BEX_UI_TEST_") }
    guard artifactBuild else {
      // Even malformed metadata/selector claims reject on ordinary Debug/Release.
      return requested || artifactMarker != nil || bundleIdentifier != "com.bex.desktop"
        ? .rejectedUITesting : .production
    }
    guard debugBuild,
      bundleIdentifier == artifactBundleIdentifier,
      artifactMarker as? String == artifactMarkerValue,
      testArguments.allSatisfy({ ["--ui-testing", "--ui-testing-system-target",
        "--missing-credential", "--open-fix-and-send", "--bex-ui-artifact-probe"].contains($0) }),
      environment["BEX_UI_TESTING"].map({ $0 == "1" }) ?? true,
      environment["BEX_UI_TEST_REAL_TARGET"].map({ $0 == "0" || $0 == "1" }) ?? true
    else { return .rejectedUITesting }
    let realTarget = environment["BEX_UI_TEST_REAL_TARGET"] == "1"
    let manualTarget = arguments.contains("--ui-testing-system-target")
    guard realTarget == manualTarget else { return .rejectedUITesting }
    // Zero selectors (including an arg/env-free relaunch) are always fixtures.
    // Manual system capabilities are never remembered across a stripped relaunch.
    return manualTarget ? .manualSystemTargetTesting : .isolatedUITesting
  }
}
