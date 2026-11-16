import CoreGraphics
import Testing

@testable import EmojiMatch

@Suite struct EmojiMatchPanelGeometryTests {
  @Test func outsideClicksDismissButPickerAndAuxiliaryMenuClicksRemainUsable() {
    let picker = CGRect(x: 100, y: 100, width: 320, height: 444)
    let menu = CGRect(x: 300, y: 200, width: 180, height: 100)
    #expect(
      !EmojiMatchPanelGeometry.shouldDismissClick(
        at: CGPoint(x: 110, y: 110), picker: picker, auxiliary: []))
    #expect(
      !EmojiMatchPanelGeometry.shouldDismissClick(
        at: CGPoint(x: 450, y: 220), picker: picker, auxiliary: [menu]))
    #expect(
      EmojiMatchPanelGeometry.shouldDismissClick(
        at: CGPoint(x: 20, y: 20), picker: picker, auxiliary: [menu]))
  }

  @Test func zeroWidthCaretPreservesCoordinates() {
    #expect(
      EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: CGRect(x: 304, y: 173, width: 0, height: 14), primaryScreenHeight: 982)
        == CGRect(x: 304, y: 795, width: 0, height: 14))
  }

  @Test func displayAbovePrimaryUsesPrimaryBaseline() {
    #expect(
      EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: CGRect(x: 100, y: -500, width: 1, height: 20), primaryScreenHeight: 982)
        == CGRect(x: 100, y: 1462, width: 1, height: 20))
  }

  @Test func displayLeftOfPrimaryPreservesNegativeX() {
    #expect(
      EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: CGRect(x: -800, y: 200, width: 1, height: 20), primaryScreenHeight: 982)
        == CGRect(x: -800, y: 762, width: 1, height: 20))
  }

  @Test func displayBelowPrimaryPreservesNegativeAppKitY() {
    #expect(
      EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: CGRect(x: 100, y: 1200, width: 1, height: 20), primaryScreenHeight: 982)
        == CGRect(x: 100, y: -238, width: 1, height: 20))
  }
}
