import AppKit
import Darwin
import DesignSystem
import ObjectiveC
import SwiftUI

struct GenmojiButtonArtwork: View {
  var presentationID = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    NativeGenmojiArtwork(
      reduceMotion: reduceMotion,
      presentationID: presentationID,
      tint: NSColor(Color.ds.textPrimary)
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct NativeGenmojiArtwork: NSViewRepresentable {
  let reduceMotion: Bool
  let presentationID: Int
  let tint: NSColor

  func makeNSView(context: Context) -> ArtworkView {
    ArtworkView()
  }

  func updateNSView(_ view: ArtworkView, context: Context) {
    view.configure(reduceMotion: reduceMotion, presentationID: presentationID, tint: tint)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArtworkView, context: Context) -> CGSize?
  {
    nsView.intrinsicContentSize
  }

  static func dismantleNSView(_ view: ArtworkView, coordinator: Void) {
    view.stop()
  }

  final class ArtworkView: NSView {
    private let imageView = NSImageView(image: NativeAnimation.makeImage())
    private let animationView: NSView?
    private var reduceMotion = true
    private var presentationID: Int?

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
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        stop()
      } else {
        roll()
      }
    }

    func configure(reduceMotion: Bool, presentationID: Int, tint: NSColor) {
      imageView.contentTintColor = tint
      let shouldRoll =
        self.reduceMotion && !reduceMotion
        || self.presentationID.map { $0 != presentationID } == true
      self.reduceMotion = reduceMotion
      self.presentationID = presentationID
      if reduceMotion {
        stop()
      } else if shouldRoll {
        roll()
      }
    }

    func stop() {
      animationView?.perform(NativeAnimation.detach)
      imageView.isHidden = false
    }

    private func roll() {
      guard !reduceMotion, window != nil else { return }
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

  static func makeImage() -> NSImage {
    let selector = NSSelectorFromString("imageWithPrivateSystemSymbolName:")
    if let method = class_getClassMethod(NSImage.self, selector),
      let encoding = method_getTypeEncoding(method),
      String(cString: encoding) == "@24@0:8@16",
      let symbol = NSImage.perform(selector, with: "emoji.face.grinning.and.plus.inverse")?
        .takeUnretainedValue() as? NSImage,
      let configured = symbol.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    {
      return configured
    }
    return NSImage(named: "Genmoji") ?? NSImage()
  }

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
