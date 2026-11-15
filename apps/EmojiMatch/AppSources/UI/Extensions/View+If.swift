import SwiftUI

extension View {
  @ViewBuilder
  func `if`<TrueContent: View, FalseContent: View>(
    _ condition: Bool,
    _ ifTransform: (Self) -> TrueContent,
    `else` elseTransform: (Self) -> FalseContent
  ) -> some View {
    if condition {
      ifTransform(self)
    } else {
      elseTransform(self)
    }
  }
}
