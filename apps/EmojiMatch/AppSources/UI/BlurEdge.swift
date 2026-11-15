import SwiftUI

struct BlurEdge: View {
  enum Direction {
    case up
    case down

    var startPoint: UnitPoint {
      switch self {
      case .up: .top
      case .down: .bottom
      }
    }

    var endPoint: UnitPoint {
      switch self {
      case .up: .bottom
      case .down: .top
      }
    }
  }

  let height: CGFloat
  let direction: Direction

  var body: some View {
    Rectangle()
      .fill(.ultraThickMaterial)
      .frame(height: height)
      .mask {
        LinearGradient(
          stops: [
            .init(color: .clear, location: .zero),
            .init(color: .black.opacity(0.5), location: 0.4),
            .init(color: .black.opacity(0.7), location: 0.7),
            .init(color: .black, location: 1)
          ],
          startPoint: direction.startPoint,
          endPoint: direction.endPoint
        )
      }
  }
}

#Preview {
  VStack {
    BlurEdge(height: 100, direction: .down)
    BlurEdge(height: 100, direction: .up)
  }
}
