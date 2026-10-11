import AppKit
import Network
import Observation
import SwiftUI

/// AppKit owns the persistent center island and the transparent expanded window.
/// SwiftUI owns the usage content; there is exactly one glass-effect layer.
@MainActor
final class QuotaBarDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore(provider: CodexAppServerUsageProvider())
    private var compactSize = NSSize(width: 168, height: NSStatusBar.system.thickness)
    private var contentSize = NSSize(width: UsagePopover.designWidth, height: UsagePopover.contentHeight)
    private var hostingTopConstraint: NSLayoutConstraint?
    private var collapseWidthConstraint: NSLayoutConstraint?
    private var collapseHeightConstraint: NSLayoutConstraint?
    private let animationMargin: CGFloat = 32
    private var compactPanel: NSPanel?
    private var panel: UsagePanel?
    private var presentationAnimator: PanelPresentationAnimator?
    private var cameraShade: CameraGlassShadeView?
    private var compactRingReveal: CompactRingRevealView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let networkMonitor = NWPathMonitor()
    private var networkAvailable: Bool?
    private var isSleeping = false
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        createCompactPanel()
        positionPanels()
        observeCompactUsage()
        (compactPanel?.contentView as? NotchButton)?.startEyesAnimation()
        compactPanel?.orderFrontRegardless()
        if ProcessInfo.processInfo.arguments.contains("--preview-eye-anger") {
            let arguments = ProcessInfo.processInfo.arguments
            let delayIndex = arguments.firstIndex(of: "--preview-delay").map { $0 + 1 }
            let delay = delayIndex.flatMap { arguments.indices.contains($0) ? Double(arguments[$0]) : nil } ?? 4
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, min(60, delay))))
                guard let self, self.compactPanel?.isVisible == true,
                      self.presentationAnimator?.isPresented != true else { return }
                (self.compactPanel?.contentView as? NotchButton)?.previewAnnoyance()
            }
        }
        store.startAutomaticRefresh()
        observeRefreshAvailability()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func observeRefreshAvailability() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating else { return }
                let previous = self.networkAvailable
                self.networkAvailable = available
                if !available {
                    self.store.suspendAutomaticRefresh()
                } else if previous == false && !self.isSleeping {
                    self.store.resumeAutomaticRefresh()
                }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.zhuxc02.quotabar.network"))
    }

    @objc private func willSleep() {
        isSleeping = true
        store.suspendAutomaticRefresh()
    }

    @objc private func didWake() {
        isSleeping = false
        if networkAvailable != false { store.resumeAutomaticRefresh() }
    }

    private func createPanel() {
        let panel = UsagePanel(contentRect: NSRect(origin: .zero, size: contentSize),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.title = "Codex 用量"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Window-server shadows outlive the layer morph and pop off at orderOut.
        // The surface owns a synchronized shadow in the transparent margin.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        self.panel = panel

        let content = UsagePopover(store: store)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                self?.resizePanel(to: size)
            }
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container
        // Real transparent window space lets the live glass overshoot without
        // being cut off by the window server at its resting size.
        let surface = NotchSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        let shadow = NotchShadowView()
        shadow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(shadow, positioned: .below, relativeTo: surface)
        surface.shadowView = shadow
        NSLayoutConstraint.activate([
            shadow.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            shadow.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            shadow.topAnchor.constraint(equalTo: surface.topAnchor),
            shadow.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: animationMargin),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -animationMargin),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -animationMargin)
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 16
            glass.tintColor = .clear
            let foreground = makeGlassForeground(hosting: hosting)
            // Keep the opaque camera surround above all system glass rendering.
            cameraShade?.maskMaterial(glass)
            glass.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(glass)
            surface.addSubview(foreground)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: NotchSurfaceView.shoulderWidth),
                glass.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -NotchSurfaceView.shoulderWidth),
                glass.topAnchor.constraint(equalTo: surface.topAnchor),
                glass.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                foreground.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                foreground.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                foreground.topAnchor.constraint(equalTo: surface.topAnchor),
                foreground.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
            ])
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 16
            material.layer?.masksToBounds = true
            material.translatesAutoresizingMaskIntoConstraints = false
            let foreground = makeGlassForeground(hosting: hosting)
            cameraShade?.maskMaterial(material)
            surface.addSubview(material)
            surface.addSubview(foreground)
            NSLayoutConstraint.activate([
                material.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: NotchSurfaceView.shoulderWidth),
                material.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -NotchSurfaceView.shoulderWidth),
                material.topAnchor.constraint(equalTo: surface.topAnchor),
                material.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                foreground.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                foreground.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                foreground.topAnchor.constraint(equalTo: surface.topAnchor),
                foreground.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
            ])
        }
        panel.onDismiss = { [weak self] in self?.hidePanel() }
        presentationAnimator = PanelPresentationAnimator(panel: panel, contentView: hosting, surfaceView: surface)
        presentationAnimator?.onSurfaceScaleAnimation = { [weak self] scales, keyTimes, duration in
            self?.cameraShade?.animate(verticalScales: scales, keyTimes: keyTimes, duration: duration)
        }
        presentationAnimator?.onCompactRingAnimation = { [weak self] scales, keyTimes, duration, presented in
            self?.compactRingReveal?.animate(scales: scales, keyTimes: keyTimes, duration: duration, presented: presented)
        }
        presentationAnimator?.onSurfaceReset = { [weak self] in
            self?.cameraShade?.resetAnimation()
            self?.compactRingReveal?.resetAnimation()
        }
        presentationAnimator?.onWillFinishClosing = { [weak self] in
            self?.positionPanels()
            self?.compactPanel?.orderFrontRegardless()
            (self?.compactPanel?.contentView as? NotchButton)?.startEyesAnimation(arriving: true)
        }
    }

    private func makeGlassForeground(hosting: NSView) -> NSView {
        let foreground = NSView()
        foreground.translatesAutoresizingMaskIntoConstraints = false

        let shade = CameraGlassShadeView(frame: .zero)
        cameraShade = shade
        shade.translatesAutoresizingMaskIntoConstraints = false
        let ringReveal = CompactRingRevealView(frame: .zero)
        compactRingReveal = ringReveal
        ringReveal.translatesAutoresizingMaskIntoConstraints = false
        let collapseButton = NSButton()
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.title = ""
        collapseButton.isBordered = false
        collapseButton.focusRingType = .none
        collapseButton.target = self
        collapseButton.action = #selector(collapseFromIsland)
        collapseButton.toolTip = "收起"
        collapseButton.setAccessibilityLabel("收起 Codex 用量")
        foreground.addSubview(shade)
        foreground.addSubview(hosting)
        foreground.addSubview(ringReveal)
        foreground.addSubview(collapseButton)
        let hostingTop = hosting.topAnchor.constraint(equalTo: foreground.topAnchor)
        let collapseWidth = collapseButton.widthAnchor.constraint(equalToConstant: compactSize.width)
        let collapseHeight = collapseButton.heightAnchor.constraint(equalToConstant: compactSize.height)
        hostingTopConstraint = hostingTop
        collapseWidthConstraint = collapseWidth
        collapseHeightConstraint = collapseHeight
        NSLayoutConstraint.activate([
            shade.leadingAnchor.constraint(equalTo: foreground.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: foreground.trailingAnchor),
            shade.topAnchor.constraint(equalTo: foreground.topAnchor),
            shade.bottomAnchor.constraint(equalTo: foreground.bottomAnchor),
            ringReveal.leadingAnchor.constraint(equalTo: foreground.leadingAnchor),
            ringReveal.trailingAnchor.constraint(equalTo: foreground.trailingAnchor),
            ringReveal.topAnchor.constraint(equalTo: foreground.topAnchor),
            ringReveal.bottomAnchor.constraint(equalTo: foreground.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: foreground.leadingAnchor, constant: NotchSurfaceView.shoulderWidth),
            hosting.trailingAnchor.constraint(equalTo: foreground.trailingAnchor, constant: -NotchSurfaceView.shoulderWidth),
            hostingTop,
            hosting.bottomAnchor.constraint(equalTo: foreground.bottomAnchor),
            collapseButton.centerXAnchor.constraint(equalTo: foreground.centerXAnchor),
            collapseButton.topAnchor.constraint(equalTo: foreground.topAnchor),
            collapseWidth,
            collapseHeight
        ])
        return foreground
    }

    private func createCompactPanel() {
        let compact = NSPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        compact.isOpaque = false
        compact.backgroundColor = .clear
        compact.hasShadow = false
        compact.acceptsMouseMovedEvents = true
        compact.level = .popUpMenu
        compact.hidesOnDeactivate = false
        compact.isReleasedWhenClosed = false
        compact.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let button = NotchButton(frame: NSRect(origin: .zero, size: compactSize))
        button.title = ""
        button.isBordered = false
        button.focusRingType = .none
        button.target = self
        button.action = #selector(openFromCompactIsland)
        button.toolTip = "查看 Codex 剩余额度"
        button.setAccessibilityLabel("打开 Codex 用量")
        compact.contentView = button
        compactPanel = compact
    }

    private func resizePanel(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let measuredSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard contentSize != measuredSize else { return }
        contentSize = measuredSize
        positionPanels()
    }

    private func positionPanels() {
        // Keep the island attached to the camera when another display gains focus.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main else { return }
        var centerX = screen.frame.midX
        let top = screen.frame.maxY
        let menuHeight = screen.frame.maxY - screen.visibleFrame.maxY
        var cameraWidth: CGFloat = 0
        var cameraHeight: CGFloat = 0
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            cameraWidth = right.minX - left.maxX
            cameraHeight = screen.safeAreaInsets.top
            centerX = (left.maxX + right.minX) / 2
            compactSize = NSSize(width: cameraWidth + 56 * 2, height: cameraHeight)
        } else {
            compactSize = NSSize(width: 168,
                                 height: menuHeight > 0 ? menuHeight : NSStatusBar.system.thickness)
        }
        // The new design already reserves the real 32pt camera height inside
        // its header. Only add clearance if a display has a taller camera.
        let contentTop = max(0, cameraHeight - UsagePopover.designCameraHeight)
        hostingTopConstraint?.constant = contentTop
        cameraShade?.cameraHeight = max(UsagePopover.designCameraHeight, cameraHeight)
        compactRingReveal?.cameraWidth = cameraWidth
        compactRingReveal?.compactSize = compactSize
        // Keep the invisible collapse target between the two header buttons.
        // A full-notch-width target would intercept the new More menu.
        collapseWidthConstraint?.constant = cameraWidth > 0 ? cameraWidth : 185
        collapseHeightConstraint?.constant = compactSize.height
        presentationAnimator?.compactSize = compactSize
        presentationAnimator?.cameraWidth = cameraWidth
        if let compactPanel {
            compactPanel.setContentSize(compactSize)
            (compactPanel.contentView as? NotchButton)?.cameraWidth = cameraWidth
            compactPanel.setFrameOrigin(NSPoint(
                x: centerX - compactPanel.frame.width / 2,
                y: top - compactPanel.frame.height
            ))
        }
        if let panel {
            let size = NSSize(width: contentSize.width + NotchSurfaceView.shoulderWidth * 2 + animationMargin * 2,
                              height: contentSize.height + contentTop + animationMargin)
            let frame = NSRect(x: centerX - size.width / 2, y: top - size.height,
                               width: size.width, height: size.height)
            if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
        }
    }

    private func observeCompactUsage() {
        withObservationTracking {
            let remaining = store.snapshot?.primary?.remainingPercent
            (compactPanel?.contentView as? NotchButton)?.remainingPercent = remaining
            compactRingReveal?.remainingPercent = remaining
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCompactUsage() }
        }
    }

    private func showPanel() {
        guard let presentationAnimator else { return }
        guard !presentationAnimator.isPresented else { return }
        store.setExpanded(true)
        positionPanels()
        // Keep the compact island for the first instant so the surface appears
        // to grow out of it instead of blinking between two separate windows.
        presentationAnimator.setPresented(true, anchorX: animationAnchorX)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
            guard self?.presentationAnimator?.isPresented == true else { return }
            self?.compactPanel?.orderOut(nil)
            // Keep the live eye pose until its window is hidden; resetting
            // during the overlap would visibly snap a blink or a glance.
            (self?.compactPanel?.contentView as? NotchButton)?.stopEyesAnimation()
        }
        installMonitors()
    }

    @objc private func openFromCompactIsland() {
        showPanel()
    }

    @objc private func collapseFromIsland() {
        hidePanel()
    }

    private func hidePanel() {
        store.setExpanded(false)
        presentationAnimator?.setPresented(false, anchorX: animationAnchorX)
        removeMonitors()
    }

    private var animationAnchorX: CGFloat {
        (panel?.frame.width ?? UsagePopover.designWidth) / 2
    }

    @objc private func screenParametersDidChange() {
        positionPanels()
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumeEvent = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.hidePanel()
                    return true
                }
                if event.type != .keyDown,
                   event.window !== self.panel {
                    self.hidePanel()
                }
                return false
            }
            return consumeEvent ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        presentationAnimator?.stopImmediately()
        (compactPanel?.contentView as? NotchButton)?.stopEyesAnimation()
        removeMonitors()
        compactPanel?.orderOut(nil)
        NotificationCenter.default.removeObserver(self)
    }
}

private final class UsagePanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
