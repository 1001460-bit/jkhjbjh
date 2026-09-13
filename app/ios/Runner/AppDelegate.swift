import Flutter
import flutter_foreground_task
import flutter_sharing_intent
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  // MARK: - Background keep-alive

  /// Channel name used to talk to the Flutter side
  /// (`BackgroundKeepAliveService`).
  private static let backgroundKeepAliveChannelName =
    "dev.ultrasend/background_keep_alive"

  /// When `true`, the app requests background execution time and plays a
  /// silent audio loop so active file transfers can continue after the app
  /// leaves the foreground. Defaults to `false` (original behaviour).
  private var backgroundKeepAliveEnabled = false

  /// Identifier returned by `beginBackgroundTask`, or
  /// `UIBackgroundTaskIdentifier.invalid` when no task is active.
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

  /// Silent audio player used to keep the app runnable in the background.
  /// Playing silent audio with the `audio` background mode is the standard
  /// way to maintain an active background process on iOS.
  private var silentAudioPlayer: AVAudioPlayer?

  /// Whether the silent audio loop is currently playing.
  private var isSilentAudioPlaying = false

  /// Flutter method channel for the keep-alive feature.
  private var backgroundKeepAliveChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "dev.ultrasend/file_times",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { call, result in
        guard call.method == "applyReceived" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              let modifiedMs = args["modifiedMs"] as? Int,
              let createdMs = args["createdMs"] as? Int else {
          result(FlutterError(code: "INVALID_ARG", message: "missing args", details: nil))
          return
        }
        let url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.creationDate = Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
        values.contentModificationDate = Date(timeIntervalSince1970: Double(modifiedMs) / 1000.0)
        do {
          var mutableUrl = url
          try mutableUrl.setResourceValues(values)
          result(true)
        } catch {
          result(FlutterError(code: "SET_FAILED", message: error.localizedDescription, details: nil))
        }
      }

      // Set up the native tab bar channel and its coordinator controller
      // Only register on iOS 26+ where Liquid Glass is available.
      if #available(iOS 26.0, *) {
        let nativeTabBarChannel = FlutterMethodChannel(
          name: "dev.ultrasend/native_tab_bar",
          binaryMessenger: controller.binaryMessenger
        )
        let nativeTabBarController = NativeTabBarController(
          flutterViewController: controller,
          channel: nativeTabBarChannel
        )
        nativeTabBarChannel.setMethodCallHandler { call, result in
          if call.method == "updateState" {
            if let args = call.arguments as? [String: Any] {
              nativeTabBarController.updateState(arguments: args)
              result(true)
            } else {
              result(FlutterError(code: "INVALID_ARG", message: "arguments must be a dictionary", details: nil))
            }
          } else if call.method == "setVisible" {
            if let visible = call.arguments as? Bool {
              nativeTabBarController.setForceHidden(!visible)
              result(true)
            } else {
              result(FlutterError(code: "INVALID_ARG", message: "argument must be a boolean", details: nil))
            }
          } else {
            result(FlutterMethodNotImplemented)
          }
        }
      }
    }

    // Set up the background keep-alive method channel so Flutter can toggle
    // the feature on/off.
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: AppDelegate.backgroundKeepAliveChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleBackgroundKeepAliveCall(call, result: result)
      }
      backgroundKeepAliveChannel = channel
    }

    return didFinish
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    let sharingIntent = SwiftFlutterSharingIntentPlugin.instance
    if sharingIntent.hasSameSchemePrefix(url: url) {
      return sharingIntent.application(app, open: url, options: options)
    }
    return super.application(app, open: url, options: options)
  }

  // MARK: - Background lifecycle

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)

    // If the user has NOT enabled background continuous transfer, keep the
    // original behaviour: do nothing and let iOS suspend the app normally.
    guard backgroundKeepAliveEnabled else {
      return
    }

    startBackgroundKeepAlive()
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    stopBackgroundKeepAlive()
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    super.applicationWillTerminate(application)
    stopBackgroundKeepAlive()
  }

  // MARK: - Background keep-alive helpers

  /// Requests extra background execution time via `beginBackgroundTask` and
  /// starts a silent audio loop. The silent audio (with the `audio`
  /// background mode in Info.plist) is what keeps the process actively
  /// runnable in the background; `beginBackgroundTask` provides the initial
  /// grace window and a clean expiration handler.
  private func startBackgroundKeepAlive() {
    // End any previously running task first.
    endBackgroundTaskIfNeeded()

    // 1. Request a finite-length background task. iOS typically grants
    //    ~30 s – several minutes; the expiration handler cleans up.
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(
      withName: "ShrimpSendBackgroundTransfer"
    ) { [weak self] in
      // Time is about to expire. If silent audio is still running it will
      // keep the process alive, but we notify Flutter so it can finish up.
      self?.backgroundKeepAliveChannel?.invokeMethod(
        "onBackgroundTaskExpiring",
        arguments: nil
      )
      self?.endBackgroundTaskIfNeeded()
    }

    // 2. Start the silent audio loop for indefinite background execution.
    startSilentAudioLoop()
  }

  /// Stops the background keep-alive: ends the background task and stops the
  /// silent audio player.
  private func stopBackgroundKeepAlive() {
    endBackgroundTaskIfNeeded()
    stopSilentAudioLoop()
  }

  private func endBackgroundTaskIfNeeded() {
    guard backgroundTaskID != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTaskID)
    backgroundTaskID = .invalid
  }

  // MARK: - Silent audio loop

  /// Generates a 1-second silent WAV buffer in memory and loops it with
  /// `AVAudioPlayer`. Configures the audio session for `.playback` so it is
  /// allowed to continue in the background.
  private func startSilentAudioLoop() {
    guard !isSilentAudioPlaying else { return }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      NSLog("[BackgroundKeepAlive] AVAudioSession config failed: \(error)")
      // Continue anyway — the background task alone may be enough for short
      // transfers.
    }

    do {
      let silentData = AppDelegate.makeSilentWAVData(duration: 1.0)
      let player = try AVAudioPlayer(data: silentData, fileTypeHint: AVFileType.wav.rawValue)
      player.numberOfLoops = -1  // loop indefinitely
      player.volume = 0.0
      player.prepareToPlay()
      player.play()
      silentAudioPlayer = player
      isSilentAudioPlaying = true
      NSLog("[BackgroundKeepAlive] silent audio loop started")
    } catch {
      NSLog("[BackgroundKeepAlive] silent audio player failed: \(error)")
    }
  }

  private func stopSilentAudioLoop() {
    guard isSilentAudioPlaying else { return }
    silentAudioPlayer?.stop()
    silentAudioPlayer = nil
    isSilentAudioPlaying = false

    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      // Best-effort deactivation.
    }
    NSLog("[BackgroundKeepAlive] silent audio loop stopped")
  }

  /// Builds a minimal 16-bit mono PCM WAV file of the given duration filled
  /// with silence (all zero samples). Avoids bundling an audio asset.
  private static func makeSilentWAVData(duration: TimeInterval) -> Data {
    let sampleRate: Int = 8000
    let bitsPerSample: Int = 16
    let channels: Int = 1
    let byteRate = sampleRate * channels * bitsPerSample / 8
    let totalSamples = Int(duration * Double(sampleRate))
    let dataSize = totalSamples * channels * bitsPerSample / 8
    let chunkSize = 36 + dataSize

    var data = Data()
    // RIFF header
    data.append(contentsOf: [UInt8]("RIFF".utf8))
    data.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
    data.append(contentsOf: [UInt8]("WAVE".utf8))
    // fmt chunk
    data.append(contentsOf: [UInt8]("fmt ".utf8))
    data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
    data.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(channels * bitsPerSample / 8).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
    // data chunk
    data.append(contentsOf: [UInt8]("data".utf8))
    data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
    data.append(Data(count: dataSize))  // silence
    return data
  }

  // MARK: - Method channel handler

  private func handleBackgroundKeepAliveCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setKeepAliveEnabled":
      guard let args = call.arguments as? [String: Any],
            let enabled = args["enabled"] as? Bool else {
        result(FlutterError(code: "INVALID_ARG", message: "missing enabled", details: nil))
        return
      }
      backgroundKeepAliveEnabled = enabled
      NSLog("[BackgroundKeepAlive] set enabled=\(enabled)")
      // If the app is already in the background and the user just enabled
      // it, start immediately.
      if enabled && UIApplication.shared.applicationState == .background {
        startBackgroundKeepAlive()
      } else if !enabled {
        stopBackgroundKeepAlive()
      }
      result(backgroundKeepAliveEnabled)

    case "isKeepAliveEnabled":
      result(backgroundKeepAliveEnabled)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

class PassThroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for subview in subviews {
            if !subview.isHidden && subview.isUserInteractionEnabled {
                let localPoint = convert(point, to: subview)
                if subview.point(inside: localPoint, with: event) {
                    return true
                }
            }
        }
        return false
    }
}

class NativeTabBarController: NSObject, NativeTabBarViewDelegate {
    private let flutterViewController: FlutterViewController
    private let channel: FlutterMethodChannel
    
    private var containerView: UIView?
    private var tabBarView: NativeTabBarView?
    private var bottomConstraint: NSLayoutConstraint?
    
    private var isBarVisible = false
    private var isDesiredVisible = false
    private var isForceHidden = false
    
    init(flutterViewController: FlutterViewController, channel: FlutterMethodChannel) {
        self.flutterViewController = flutterViewController
        self.channel = channel
        super.init()
        setupTabBar()
    }
    
    private func setupTabBar() {
        let container = PassThroughView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .clear
        container.layer.masksToBounds = false
        
        let bar = NativeTabBarView()
        bar.delegate = self
        bar.translatesAutoresizingMaskIntoConstraints = false
        
        container.addSubview(bar)
        flutterViewController.view.addSubview(container)
        
        self.containerView = container
        self.tabBarView = bar
        
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: flutterViewController.view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: flutterViewController.view.trailingAnchor),
            container.heightAnchor.constraint(equalToConstant: 140),
            
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        
        let constraint = container.bottomAnchor.constraint(equalTo: flutterViewController.view.bottomAnchor, constant: 0)
        constraint.isActive = true
        self.bottomConstraint = constraint
        
        container.alpha = 0
        container.transform = CGAffineTransform(translationX: 0, y: 150)
    }
    
    func updateState(arguments: [String: Any]) {
        guard let visible = arguments["visible"] as? Bool,
              let selectedIndex = arguments["selectedIndex"] as? Int,
              let badgeCount = arguments["badgeCount"] as? Int,
              let primaryColorHex = arguments["primaryColorHex"] as? String,
              let connectLabel = arguments["connectLabel"] as? String,
              let filesLabel = arguments["filesLabel"] as? String,
              let settingsLabel = arguments["settingsLabel"] as? String else {
            return
        }
        
        let isDarkMode = arguments["isDarkMode"] as? Bool ?? false
        if #available(iOS 13.0, *) {
            containerView?.overrideUserInterfaceStyle = isDarkMode ? .dark : .light
        }
        
        tabBarView?.update(
            selectedIndex: selectedIndex,
            badgeCount: badgeCount,
            primaryColorHex: primaryColorHex,
            connectLabel: connectLabel,
            filesLabel: filesLabel,
            settingsLabel: settingsLabel
        )
        
        self.isDesiredVisible = visible
        updateVisibility()
    }
    
    func setForceHidden(_ forceHidden: Bool) {
        guard self.isForceHidden != forceHidden else { return }
        self.isForceHidden = forceHidden
        updateVisibility()
    }
    
    private func updateVisibility() {
        let shouldBeVisible = isDesiredVisible && !isForceHidden
        guard isBarVisible != shouldBeVisible else { return }
        isBarVisible = shouldBeVisible
        
        flutterViewController.view.layoutIfNeeded()
        
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialVelocity: 0.5,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: { [weak self] in
                guard let self = self else { return }
                if shouldBeVisible {
                    self.containerView?.alpha = 1
                    self.containerView?.transform = .identity
                    self.bottomConstraint?.constant = 0
                } else {
                    self.containerView?.alpha = 0
                    self.containerView?.transform = CGAffineTransform(translationX: 0, y: 150)
                    self.bottomConstraint?.constant = 150
                }
                self.flutterViewController.view.layoutIfNeeded()
            },
            completion: nil
        )
    }
    
    // MARK: - NativeTabBarViewDelegate
    
    func tabBarView(_ tabBarView: NativeTabBarView, didSelectTabAt index: Int) {
        channel.invokeMethod("selectTab", arguments: index)
    }
    
    func tabBarViewDidTapOutbox(_ tabBarView: NativeTabBarView) {
        channel.invokeMethod("openPendingFiles", arguments: nil)
    }
}
