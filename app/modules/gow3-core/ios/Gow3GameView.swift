// SPDX-License-Identifier: GPL-3.0-or-later
// The native fullscreen view the GPU draws into: a CAMetalLayer-backed view in a view controller
// presented over React Native, which stays idle behind it. The MoltenVK screen test and the game's
// Vulkan presenter (gow3_gpu_set_surface) draw into it.
import QuartzCore
import UIKit

@_silgen_name("gow3_set_suspended")
private func gow3_set_suspended(_ suspended: Int32)
@_silgen_name("gow3_is_suspended")
private func gow3_is_suspended() -> Int32
@_silgen_name("gow3_pad_trigger_select")
private func gow3_pad_trigger_select()

extension Notification.Name {
  static let gow3SessionStateChanged = Notification.Name("Gow3SessionStateChanged")
}

final class Gow3MetalView: UIView {
  override class var layerClass: AnyClass { CAMetalLayer.self }
  var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

final class Gow3GameViewController: UIViewController, UIGestureRecognizerDelegate {
  static var shared: Gow3GameViewController?

  let metalView = Gow3MetalView()
  private var touchControls: Gow3TouchControlsView?

  override func loadView() {
    metalView.backgroundColor = .black
    view = metalView
  }

  /// The game presents into this view's layer: its size goes to the GPU library on every layout.
  var feedsGame = false

  override func viewDidLoad() {
    super.viewDidLoad()
    let hide = UITapGestureRecognizer(target: self, action: #selector(hideGameView))
    hide.numberOfTouchesRequired = 2
    hide.numberOfTapsRequired = 2
    // Not from touches on the on-screen controls: two thumbs tapping buttons would hide the game.
    hide.delegate = self
    view.addGestureRecognizer(hide)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    touch.view === metalView
  }

  /// The on-screen controls (Gow3TouchControls.swift) over the game.
  func addTouchControls() {
    guard touchControls == nil else { return }
    let controls = Gow3TouchControlsView(frame: view.bounds)
    controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controls.onSuspendRequest = { [weak self] in
      self?.suspendToLauncher(triggerSelect: true)
    }
    view.addSubview(controls)
    touchControls = controls
  }

  func refreshTouchControls() {
    touchControls?.refreshVisibility()
  }

  @objc private func hideGameView() {
    suspendToLauncher(triggerSelect: true)
  }

  /// Cleanly freezes GPU/audio/watchdog, sends an optional Select pause pulse, and returns to the launcher
  /// while keeping this view controller and its CAMetalLayer alive for instant resume without re-enabling JIT.
  func suspendToLauncher(triggerSelect: Bool = true, completion: (() -> Void)? = nil) {
    guard feedsGame else {
      completion?()
      return
    }
    touchControls?.releaseAllInputs()
    if triggerSelect && gow3_is_suspended() == 0 {
      gow3_pad_trigger_select()
    }
    gow3_set_suspended(1)
    NotificationCenter.default.post(name: .gow3SessionStateChanged, object: nil)
    if presentingViewController != nil {
      dismiss(animated: false) {
        NotificationCenter.default.post(name: .gow3SessionStateChanged, object: nil)
        completion?()
      }
    } else {
      completion?()
    }
  }

  /// Hands the layer, its pixel size and the screen's maximum refresh rate to the GPU library.
  func publishSurface() {
    let layer = metalView.metalLayer
    let size = layer.drawableSize
    guard size.width > 0, size.height > 0 else { return }
    let hz = view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
    gow3_gpu_set_surface(Unmanaged.passUnretained(layer).toOpaque(), UInt32(size.width), UInt32(size.height), UInt32(hz))
  }

  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  // The game is 16:9: landscape only while this view is up (app.json allows every orientation).
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

  // The drawable follows the view in pixels (MoltenVK sizes the swapchain from it), at most 2x:
  // the game renders at 600-720p, so the 3x screen (2622x1206) only made the final full-screen
  // pass and the present more than twice as large, for no sharper picture.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let scale = min(view.window?.screen.nativeScale ?? UIScreen.main.nativeScale, 2)
    metalView.metalLayer.contentsScale = scale
    metalView.metalLayer.drawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
    if feedsGame { publishSurface() }
  }

  static func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else {
      return nil
    }
    while let presented = top.presentedViewController { top = presented }
    return top
  }

  /// Presents a new one fullscreen over the topmost view controller; nil when there is no key window.
  static func present(completion: @escaping (Gow3GameViewController?) -> Void) {
    guard let top = topViewController() else {
      completion(nil)
      return
    }
    let controller = Gow3GameViewController()
    controller.modalPresentationStyle = .fullScreen
    // Without this, the presenting React Native controller keeps deciding the status bar.
    controller.modalPresentationCapturesStatusBarAppearance = true
    top.present(controller, animated: false) {
      controller.view.layoutIfNeeded()
      completion(controller)
    }
  }

  /// Re-presents the suspended game view controller and unparks GPU/audio threads immediately.
  static func resume(completion: @escaping (Bool) -> Void) {
    guard let controller = shared else {
      completion(false)
      return
    }
    if controller.presentingViewController != nil {
      controller.refreshTouchControls()
      controller.publishSurface()
      gow3_set_suspended(0)
      NotificationCenter.default.post(name: .gow3SessionStateChanged, object: nil)
      completion(true)
      return
    }
    guard let top = topViewController() else {
      completion(false)
      return
    }
    top.present(controller, animated: false) {
      controller.view.layoutIfNeeded()
      controller.refreshTouchControls()
      controller.publishSurface()
      gow3_set_suspended(0)
      NotificationCenter.default.post(name: .gow3SessionStateChanged, object: nil)
      completion(true)
    }
  }
}
