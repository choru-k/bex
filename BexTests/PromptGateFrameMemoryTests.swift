import AppKit
import SwiftUI
import XCTest

@testable import Bex

@MainActor
final class PromptGateFrameMemoryTests: XCTestCase {
  private let visibleFrame = NSRect(x: 100, y: 50, width: 1_200, height: 800)

  func testFreshFrameStartsCompactAndCentered() {
    var memory = PromptGateFrameMemory()
    let frame = memory.resolvedFrame(
      defaultSize: NSSize(width: 640, height: 500),
      visibleFrame: visibleFrame
    )

    XCTAssertEqual(frame.size, NSSize(width: 640, height: 500))
    XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 0.001)
    XCTAssertEqual(frame.midY, visibleFrame.midY, accuracy: 0.001)
  }

  func testAutomaticGrowthPreservesTopLeftAndNeverShrinks() {
    let roomyVisibleFrame = NSRect(x: 100, y: 50, width: 1_400, height: 1_200)
    var memory = PromptGateFrameMemory()
    let compact = memory.resolvedFrame(
      defaultSize: NSSize(width: 640, height: 500),
      visibleFrame: roomyVisibleFrame
    )
    let grown = memory.frameGrowing(
      to: NSSize(width: 820, height: 680),
      defaultSize: compact.size,
      visibleFrame: roomyVisibleFrame
    )

    XCTAssertEqual(grown.minX, compact.minX, accuracy: 0.001)
    XCTAssertEqual(grown.maxY, compact.maxY, accuracy: 0.001)
    XCTAssertEqual(grown.size, NSSize(width: 820, height: 680))

    let smallerRequirement = memory.frameGrowing(
      to: NSSize(width: 620, height: 500),
      defaultSize: compact.size,
      visibleFrame: roomyVisibleFrame
    )
    XCTAssertEqual(smallerRequirement, grown)
  }

  func testUserResizeAndTopLeftWinOverLaterPhaseRequirements() {
    var memory = PromptGateFrameMemory()
    _ = memory.resolvedFrame(
      defaultSize: NSSize(width: 640, height: 500),
      visibleFrame: visibleFrame
    )
    let userFrame = NSRect(x: 180, y: 100, width: 940, height: 720)
    memory.rememberUserFrame(userFrame, visibleFrame: visibleFrame)

    let restored = memory.frameGrowing(
      to: NSSize(width: 760, height: 600),
      defaultSize: NSSize(width: 640, height: 500),
      visibleFrame: visibleFrame
    )
    XCTAssertEqual(restored, userFrame)

    let wider = memory.frameGrowing(
      to: NSSize(width: 1_000, height: 700),
      defaultSize: NSSize(width: 640, height: 500),
      visibleFrame: visibleFrame
    )
    XCTAssertEqual(wider.minX, userFrame.minX, accuracy: 0.001)
    XCTAssertEqual(wider.maxY, userFrame.maxY, accuracy: 0.001)
    XCTAssertEqual(wider.width, 1_000, accuracy: 0.001)
    XCTAssertEqual(wider.height, userFrame.height, accuracy: 0.001)
  }

  func testRememberedFrameIsRestoredInsideVisibleScreen() {
    var memory = PromptGateFrameMemory()
    memory.rememberUserFrame(
      NSRect(x: -900, y: 2_000, width: 1_500, height: 1_000),
      visibleFrame: visibleFrame
    )
    let restored = memory.resolvedFrame(
      defaultSize: NSSize(width: 640, height: 500),
      visibleFrame: visibleFrame
    )

    XCTAssertGreaterThanOrEqual(restored.minX, visibleFrame.minX)
    XCTAssertGreaterThanOrEqual(restored.minY, visibleFrame.minY)
    XCTAssertLessThanOrEqual(restored.maxX, visibleFrame.maxX)
    XCTAssertLessThanOrEqual(restored.maxY, visibleFrame.maxY)
  }

  func testPromptGateLayoutContractsAreExact() {
    XCTAssertEqual(
      PromptGatePanelLayout.preferredContentSize,
      NSSize(width: 640, height: 500)
    )
    XCTAssertEqual(
      PromptGatePanelLayout.minimumContentSize,
      NSSize(width: 460, height: 420)
    )
    XCTAssertEqual(
      PromptGatePanelLayout.requiredContentSize(for: .closed),
      NSSize(width: 460, height: 500)
    )
    XCTAssertEqual(
      PromptGatePanelLayout.requiredContentSize(for: .onboarding),
      NSSize(width: 460, height: 500)
    )
    XCTAssertEqual(
      PromptGatePanelLayout.requiredContentSize(for: .invalidated),
      NSSize(width: 460, height: 500)
    )
    XCTAssertEqual(
      PromptGatePanelLayout.requiredContentSize(for: .composing),
      NSSize(width: 460, height: 600)
    )
    XCTAssertEqual(
      PromptGatePanelLayout.requiredContentSize(for: .checking),
      NSSize(width: 460, height: 600)
    )
    XCTAssertEqual(
      PromptGatePanelLayout.requiredContentSize(for: .reviewing),
      NSSize(width: 460, height: 680)
    )
    XCTAssertEqual(
      PromptGatePanelLayout.requiredContentSize(for: .delivering),
      NSSize(width: 460, height: 680)
    )

    XCTAssertEqual(PromptGateLayout.finalEditorHeight(for: 0), 180)
    XCTAssertEqual(PromptGateLayout.finalEditorHeight(for: 450), 180)
    XCTAssertEqual(PromptGateLayout.finalEditorHeight(for: 500), 200)
    XCTAssertEqual(PromptGateLayout.finalEditorHeight(for: 800), 320)
    XCTAssertEqual(PromptGateLayout.finalEditorHeight(for: 1_000), 320)
  }

  func testRememberedMinimumWidthGrowsOnlyVerticallyForReview() {
    let roomyVisibleFrame = NSRect(x: 100, y: 50, width: 1_400, height: 1_200)
    let remembered = NSRect(x: 240, y: 280, width: 460, height: 500)
    var memory = PromptGateFrameMemory(restoredFrame: remembered)

    let reviewFrame = memory.frameGrowing(
      to: PromptGatePanelLayout.requiredContentSize(for: .reviewing),
      defaultSize: PromptGatePanelLayout.preferredContentSize,
      visibleFrame: roomyVisibleFrame
    )

    XCTAssertEqual(reviewFrame.width, 460, accuracy: 0.001)
    XCTAssertEqual(reviewFrame.height, 680, accuracy: 0.001)
    XCTAssertEqual(reviewFrame.minX, remembered.minX, accuracy: 0.001)
    XCTAssertEqual(reviewFrame.maxY, remembered.maxY, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(reviewFrame.minX, roomyVisibleFrame.minX)
    XCTAssertGreaterThanOrEqual(reviewFrame.minY, roomyVisibleFrame.minY)
    XCTAssertLessThanOrEqual(reviewFrame.maxX, roomyVisibleFrame.maxX)
    XCTAssertLessThanOrEqual(reviewFrame.maxY, roomyVisibleFrame.maxY)
  }

  func testAutosavedFrameSeedsMemoryAcrossControllerRecreation() throws {
    let autosaveName = NSWindow.FrameAutosaveName("BexTests.PromptGate.\(UUID().uuidString)")
    NSWindow.removeFrame(usingName: autosaveName)
    defer { NSWindow.removeFrame(usingName: autosaveName) }
    let visibleFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
    let width = min(900, visibleFrame.width)
    let height = min(700, visibleFrame.height)
    let savedFrame = NSRect(
      x: visibleFrame.minX,
      y: visibleFrame.maxY - height,
      width: width,
      height: height
    )

    do {
      let controller = PromptGatePanelController(
        rootView: AnyView(EmptyView()),
        cancelAction: {},
        frameAutosaveName: autosaveName
      )
      let window = try XCTUnwrap(controller.window)
      window.setFrame(savedFrame, display: false)
      _ = window.setFrameAutosaveName("")
      window.saveFrame(usingName: autosaveName)
    }

    let restoredController = PromptGatePanelController(
      rootView: AnyView(EmptyView()),
      cancelAction: {},
      frameAutosaveName: autosaveName
    )
    let restoredWindow = try XCTUnwrap(restoredController.window)
    let restoredFrame = restoredWindow.frame
    restoredController.accommodate(.onboarding)

    XCTAssertEqual(restoredWindow.frame.minX, restoredFrame.minX, accuracy: 0.001)
    XCTAssertEqual(restoredWindow.frame.maxY, restoredFrame.maxY, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(restoredWindow.frame.width, restoredFrame.width)
    XCTAssertGreaterThanOrEqual(restoredWindow.frame.height, restoredFrame.height)
    XCTAssertGreaterThanOrEqual(restoredWindow.frame.minX, visibleFrame.minX)
    XCTAssertGreaterThanOrEqual(restoredWindow.frame.minY, visibleFrame.minY)
    XCTAssertLessThanOrEqual(restoredWindow.frame.maxX, visibleFrame.maxX)
    XCTAssertLessThanOrEqual(restoredWindow.frame.maxY, visibleFrame.maxY)
  }

}
