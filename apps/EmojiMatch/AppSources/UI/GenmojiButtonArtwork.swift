import AppKit
import Darwin
import ObjectiveC
import SwiftUI

struct GenmojiButtonArtwork: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    NativeGenmojiArtwork(
      reduceMotion: reduceMotion
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct NativeGenmojiArtwork: NSViewRepresentable {
  let reduceMotion: Bool

  func makeNSView(context: Context) -> ArtworkView {
    ArtworkView()
  }

  func updateNSView(_ view: ArtworkView, context: Context) {
    view.configure(reduceMotion: reduceMotion)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArtworkView, context: Context) -> CGSize?
  {
    nsView.intrinsicContentSize
  }

  static func dismantleNSView(_ view: ArtworkView, coordinator: Void) {
    view.stop()
  }

  final class ArtworkView: NSView {
    private let imageView = NSImageView(image: NSImage(named: "NativeGenmojiResting") ?? NSImage())
    private let animationView: NSView?
    private var reduceMotion = true
    private var rollPending = false

    override init(frame frameRect: NSRect) {
      animationView = NativeAnimation.makeView()
      super.init(frame: frameRect)
      imageView.imageScaling = .scaleProportionallyUpOrDown
      addSubview(imageView)
      if let animationView {
        addSubview(animationView)
        NativeAnimation.setCallback(on: animationView) { [weak self] showing in
          MainActor.assumeIsolated {
            self?.imageView.isHidden = showing
          }
        }
      }
    }

    convenience init() {
      self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
      nil
    }

    override var intrinsicContentSize: NSSize {
      NSSize(width: 16, height: 16)
    }

    override func layout() {
      super.layout()
      imageView.frame = bounds
      animationView?.frame = bounds
      if rollPending, !bounds.isEmpty {
        roll()
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        stop()
      } else {
        roll()
      }
    }

    func configure(reduceMotion: Bool) {
      let shouldRoll = self.reduceMotion && !reduceMotion
      self.reduceMotion = reduceMotion
      if reduceMotion {
        stop()
      } else if shouldRoll {
        roll()
      }
    }

    func stop() {
      rollPending = false
      animationView?.perform(NativeAnimation.detach)
      imageView.isHidden = false
    }

    private func roll() {
      guard !reduceMotion, window != nil else { return }
      rollPending = bounds.isEmpty
      guard !rollPending else { return }
      animationView?.frame = bounds
      animationView?.perform(NativeAnimation.roll)
    }
  }
}

private enum NativeAnimation {
  static let roll = NSSelectorFromString("roll")
  static let detach = NSSelectorFromString("detachAnimation")
  private static let callback = NSSelectorFromString("setShowingAnimationDidChange:")
  private static let viewClass: NSView.Type? = {
    guard
      dlopen(
        "/System/Library/PrivateFrameworks/CharacterPicker.framework/CharacterPicker", RTLD_LAZY
      ) != nil,
      let viewClass = NSClassFromString("CPKGenmojiAnimationView") as? NSView.Type
    else { return nil }
    for (selector, encoding) in [
      (roll, "v16@0:8"),
      (detach, "v16@0:8"),
      (callback, "v24@0:8@?16")
    ] {
      guard let method = class_getInstanceMethod(viewClass, selector),
        let actualEncoding = method_getTypeEncoding(method),
        String(cString: actualEncoding) == encoding
      else { return nil }
    }
    return viewClass
  }()

  static func makeView() -> NSView? {
    viewClass?.init(frame: .zero)
  }

  static func setCallback(on view: NSView, _ block: @escaping @convention(block) (Bool) -> Void) {
    typealias Setter =
      @convention(c) (
        AnyObject, Selector, @convention(block) (Bool) -> Void
      ) -> Void
    let setter = unsafeBitCast(view.method(for: callback), to: Setter.self)
    setter(view, callback, block)
  }
}
