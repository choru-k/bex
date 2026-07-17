import Foundation

struct ProviderRequest {
  static func json(
    url: URL,
    method: String = "POST",
    headers: [String: String] = [:],
    body: Any? = nil,
    timeout: TimeInterval
  ) throws -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return request
  }

  static func form(
    url: URL,
    values: [(String, String)],
    timeout: TimeInterval = 30
  ) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody =
      values
      .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
      .joined(separator: "&")
      .data(using: .utf8)
    return request
  }

  private static func formEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":#[]@!$&'()*+,;=?/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

enum ProviderResponse {
  static func data(
    for request: URLRequest,
    transport: any HTTPTransport,
    provider: LLMProvider,
    ollamaURL: String? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    do {
      return try await transport.data(for: request)
    } catch is CancellationError {
      throw BexError.cancellation
    } catch let error as URLError {
      switch error.code {
      case .cancelled:
        throw BexError.cancellation
      case .timedOut:
        throw BexError.timeout
      default:
        if provider == .ollama, let ollamaURL {
          throw BexError.connectionFailure(
            "Cannot connect to Ollama at \(ollamaURL). Make sure Ollama is running."
          )
        }
        throw BexError.connectionFailure(
          "Could not connect to \(provider.displayName). Check your internet connection."
        )
      }
    } catch let error as BexError {
      throw error
    } catch {
      if provider == .ollama, let ollamaURL {
        throw BexError.connectionFailure(
          "Cannot connect to Ollama at \(ollamaURL). Make sure Ollama is running."
        )
      }
      throw BexError.connectionFailure(
        "Could not connect to \(provider.displayName). Check your internet connection."
      )
    }
  }

  static func validateStatus(
    _ response: HTTPURLResponse,
    data: Data,
    provider: LLMProvider,
    model: String? = nil,
    ollamaURL: String? = nil
  ) throws {
    guard !(200..<300).contains(response.statusCode) else { return }

    if response.statusCode == 401
      || (response.statusCode == 403 && (provider == .gemini || provider == .openAICodex))
    {
      throw BexError.unauthorized(provider)
    }
    if response.statusCode == 429 {
      throw BexError.rateLimited
    }
    if provider == .ollama,
      let model,
      String(data: data, encoding: .utf8)?.localizedCaseInsensitiveContains("not found") == true
    {
      throw BexError.modelMissing("Model '\(model)' not found. Run: ollama pull \(model)")
    }
    if provider == .openAICodex, response.statusCode == 400,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let detail = object["detail"] as? String,
      !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw BexError.modelMissing(detail)
    }
    if provider == .gemini, response.statusCode == 400 {
      throw BexError.modelMissing("Bad request to Gemini. Check your model name and input.")
    }
    throw BexError.providerHTTPStatus(response.statusCode)
  }

  static func object(from data: Data) throws -> [String: Any] {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      throw BexError.invalidResponse
    }
    return dictionary
  }

  static func nonempty(_ value: Any?) throws -> String {
    guard let string = value as? String, !string.isEmpty else {
      throw BexError.invalidResponse
    }
    return string
  }
}
