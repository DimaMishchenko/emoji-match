import CoreGraphics

/// Resolves the best available accessibility anchor for the currently focused text input.
public enum TextAnchorResolver {
  private static var locator = TextAnchorLocator()

  /// Prefers AX caret or selection geometry, then estimates and focused input bounds.
  /// Returns `nil` when no focused text input is identifiable or Accessibility access is missing.
  public static func anchorRect() -> CGRect? {
    locator.anchorRect()
  }
}
