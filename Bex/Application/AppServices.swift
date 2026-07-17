import Foundation

@MainActor
final class AppServices {
  let preferences: PreferencesStore
  let keychain: KeychainStore
  let data: BexDataStore
  let grammar: any GrammarServicing
  let pasteboard: any PasteboardWriting
  let codexOAuth: CodexOAuthService
  let autoDismissQuickCheck: Bool

  init(
    preferences: PreferencesStore,
    keychain: KeychainStore,
    data: BexDataStore,
    grammar: any GrammarServicing,
    pasteboard: any PasteboardWriting,
    codexOAuth: CodexOAuthService,
    autoDismissQuickCheck: Bool = true
  ) {
    self.preferences = preferences
    self.keychain = keychain
    self.data = data
    self.grammar = grammar
    self.pasteboard = pasteboard
    self.codexOAuth = codexOAuth
    self.autoDismissQuickCheck = autoDismissQuickCheck
  }

  static func production() -> AppServices {
    let preferences = PreferencesStore()
    let keychain = KeychainStore()
    let data = BexDataStore()
    let transport = URLSessionTransport()
    let factory = ProviderClientFactory(
      preferences: preferences,
      keychain: keychain,
      transport: transport
    )
    return AppServices(
      preferences: preferences,
      keychain: keychain,
      data: data,
      grammar: GrammarService(factory: factory),
      pasteboard: SystemPasteboard(),
      codexOAuth: CodexOAuthService(
        keychain: keychain,
        transport: transport
      )
    )
  }
}
