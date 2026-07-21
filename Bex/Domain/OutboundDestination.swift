import Foundation

struct OutboundDestination: Equatable, Sendable {
  let provider: LLMProvider
  let model: String
  let ollamaEndpoint: String?

  init(
    provider: LLMProvider,
    model: String,
    ollamaEndpoint: String? = nil
  ) throws {
    self.provider = provider

    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    self.model = trimmedModel.isEmpty ? provider.defaultModel : trimmedModel

    if provider == .ollama {
      guard let ollamaEndpoint else { throw BexError.invalidOllamaURL }
      self.ollamaEndpoint = try OllamaURL.normalize(ollamaEndpoint)
    } else {
      self.ollamaEndpoint = nil
    }
  }

  var disclosureTarget: String {
    guard provider == .ollama, let ollamaEndpoint else {
      return provider.displayName
    }
    let location = OllamaURL.isLoopback(ollamaEndpoint)
      ? "local to this Mac"
      : "external to this Mac"
    return "Ollama at \(ollamaEndpoint) (\(location))"
  }
}

enum OllamaURL {
  static func normalize(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host,
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      throw BexError.invalidOllamaURL
    }

    components.scheme = scheme
    components.host = host.lowercased()
    var path = components.percentEncodedPath
    while path.hasSuffix("/") {
      path.removeLast()
    }
    components.percentEncodedPath = path

    guard let normalizedURL = components.url else {
      throw BexError.invalidOllamaURL
    }
    return normalizedURL.absoluteString
  }

  static func isLoopback(_ value: String) -> Bool {
    guard let host = URLComponents(string: value)?.host?.lowercased() else { return false }
    let canonicalHost = host.hasSuffix(".") ? String(host.dropLast()) : host
    if canonicalHost == "localhost" || canonicalHost.hasSuffix(".localhost")
      || canonicalHost == "::1"
    {
      return true
    }
    let octets = canonicalHost.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    let numbers = octets.compactMap { Int($0) }
    return numbers.count == 4
      && numbers[0] == 127
      && numbers.allSatisfy { (0...255).contains($0) }
  }
}
