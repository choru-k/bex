enum QuickCheckDismissalReason: Equatable, Sendable {
  case applicationDeactivated
  case auxiliaryNavigation
  case explicitCancel
  case windowClose
  case completed

  var sessionDisposition: QuickCheckSessionDisposition {
    switch self {
    case .applicationDeactivated, .auxiliaryNavigation:
      .preserve
    case .explicitCancel, .windowClose:
      .discard
    case .completed:
      .complete
    }
  }
}

enum QuickCheckSessionDisposition: Equatable, Sendable {
  case preserve
  case discard
  case complete
}
