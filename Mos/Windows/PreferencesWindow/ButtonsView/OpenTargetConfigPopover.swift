//
//  OpenTargetConfigPopover.swift
//  Mos
//  "打开应用…" 动作的配置 popover - 文件槽 + 参数 + 完成/取消
//

import Cocoa

final class OpenTargetConfigPopover: NSObject {

    // MARK: - Public callbacks
    var onCommit: ((OpenTargetPayload) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - State
    private var popover: NSPopover?
    private var existingPayload: OpenTargetPayload?

    // Captured selection
    private var selectedPath: String?
    private var selectedBundleID: String?
    private var selectedIsApplication: Bool = false

    // Views
    private weak var fileSlot: FileSlotView?
    private weak var argsSection: NSView?
    private weak var argsField: NSTextField?
    private weak var doneButton: NSButton?
    private weak var staleBanner: NSView?
    private var argsSectionHeightConstraint: NSLayoutConstraint?

    // Layout constants
    private static let contentWidth: CGFloat = 320
    private static let padding: CGFloat = 16
    private static let slotHeight: CGFloat = 64
    private static let argsSectionHeight: CGFloat = 45

    private struct PickedFile {
        let path: String
        let bundleID: String?
        let isApplication: Bool
    }

    // MARK: - Show

    func show(at sourceView: NSView, existing: OpenTargetPayload?) {
        hide()
        self.existingPayload = existing
        self.selectedPath = existing?.path
        self.selectedBundleID = existing?.bundleID
        self.selectedIsApplication = existing?.isApplication ?? false

        let popover = NSPopover()
        popover.behavior = .applicationDefined  // 不自动关闭, 必须显式 close
        popover.contentViewController = makeViewController(initialArgs: existing?.arguments ?? "")
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        self.popover = popover

        // Initial state with stale detection
        if existing != nil, isCurrentSelectionResolvable() {
            applyFilledStateForCurrentSelection(animated: false)
        } else if existing != nil {
            // Stale: show warning, fall back to empty state
            staleBanner?.isHidden = false
            selectedPath = nil
            selectedBundleID = nil
            selectedIsApplication = false
            fileSlot?.setState(.empty, animated: false)
            doneButton?.isEnabled = false
            setArgumentsVisible(false, animated: false)
        } else {
            fileSlot?.setState(.empty, animated: false)
            setArgumentsVisible(false, animated: false)
        }
    }

    private func isCurrentSelectionResolvable() -> Bool {
        guard let path = selectedPath else { return false }
        if selectedIsApplication, let bundleID = selectedBundleID,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return true
        }
        return FileManager.default.fileExists(atPath: path)
    }

    func hide() {
        popover?.close()
        popover = nil
    }

    // MARK: - View construction

    private func makeViewController(initialArgs: String) -> NSViewController {
        let vc = NSViewController()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Stale banner (initially hidden)
        let banner = makeStaleBanner()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        container.addSubview(banner)
        self.staleBanner = banner

        // File slot (empty state for now; filled state in Task 10)
        let slot = FileSlotView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.onClick = { [weak self] in self?.onFileSlotClicked() }
        slot.onClear = { [weak self] in self?.onFileSlotCleared() }
        slot.onDrop = { [weak self] url in
            guard let self = self, let picked = Self.resolvePickedFile(at: url) else { return }
            self.applyPickedFile(picked)
        }
        container.addSubview(slot)
        self.fileSlot = slot

        // Args section (collapsed until a file is selected)
        let argsSection = NSView()
        argsSection.translatesAutoresizingMaskIntoConstraints = false
        argsSection.wantsLayer = true
        argsSection.layer?.masksToBounds = true
        argsSection.alphaValue = selectedPath == nil ? 0 : 1
        container.addSubview(argsSection)
        self.argsSection = argsSection

        // Args caption
        let captionStack = NSStackView()
        captionStack.orientation = .horizontal
        captionStack.spacing = 0
        captionStack.translatesAutoresizingMaskIntoConstraints = false
        let captionLabel = NSTextField(labelWithString: NSLocalizedString("open-target-arguments-label", comment: ""))
        captionLabel.font = NSFont.systemFont(ofSize: 11)
        captionLabel.textColor = NSColor.labelColor
        let captionSuffix = NSTextField(labelWithString: " " + NSLocalizedString("open-target-arguments-optional-suffix", comment: ""))
        captionSuffix.font = NSFont.systemFont(ofSize: 11)
        captionSuffix.textColor = NSColor.tertiaryLabelColor
        captionStack.addArrangedSubview(captionLabel)
        captionStack.addArrangedSubview(captionSuffix)
        argsSection.addSubview(captionStack)

        // Args field (monospaced)
        let args = NSTextField()
        args.translatesAutoresizingMaskIntoConstraints = false
        args.bezelStyle = .roundedBezel
        args.placeholderString = NSLocalizedString("open-target-arguments-placeholder", comment: "")
        args.stringValue = initialArgs
        if #available(macOS 10.15, *) {
            args.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        } else {
            args.font = NSFont(name: "Menlo", size: 12) ?? NSFont.systemFont(ofSize: 12)
        }
        argsSection.addSubview(args)
        self.argsField = args

        // Buttons
        let cancel = NSButton(title: NSLocalizedString("open-target-cancel", comment: ""), target: self, action: #selector(onCancelButton))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        container.addSubview(cancel)

        let done = NSButton(title: NSLocalizedString("open-target-done", comment: ""), target: self, action: #selector(onDoneButton))
        done.translatesAutoresizingMaskIntoConstraints = false
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.isEnabled = (selectedPath != nil)
        container.addSubview(done)
        self.doneButton = done

        let argsHeight = argsSection.heightAnchor.constraint(equalToConstant: selectedPath == nil ? 0 : Self.argsSectionHeight)
        argsHeight.isActive = true
        self.argsSectionHeightConstraint = argsHeight

        // Layout
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth + Self.padding * 2),

            banner.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),

            slot.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
            slot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            slot.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            slot.heightAnchor.constraint(equalToConstant: Self.slotHeight),

            argsSection.topAnchor.constraint(equalTo: slot.bottomAnchor, constant: 12),
            argsSection.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            argsSection.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),

            captionStack.topAnchor.constraint(equalTo: argsSection.topAnchor),
            captionStack.leadingAnchor.constraint(equalTo: argsSection.leadingAnchor),

            args.topAnchor.constraint(equalTo: captionStack.bottomAnchor, constant: 6),
            args.leadingAnchor.constraint(equalTo: argsSection.leadingAnchor),
            args.trailingAnchor.constraint(equalTo: argsSection.trailingAnchor),
            args.heightAnchor.constraint(equalToConstant: 26),
            args.bottomAnchor.constraint(equalTo: argsSection.bottomAnchor),

            done.topAnchor.constraint(equalTo: argsSection.bottomAnchor, constant: 16),
            done.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            done.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),

            cancel.topAnchor.constraint(equalTo: done.topAnchor),
            cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
        ])

        vc.view = container
        return vc
    }

    private func makeStaleBanner() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6

        if #available(macOS 11.0, *), let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) {
            let imageView = NSImageView(image: symbol)
            imageView.contentTintColor = NSColor.systemOrange
            stack.addArrangedSubview(imageView)
        }

        let label = NSTextField(labelWithString: NSLocalizedString("open-target-stale-warning", comment: ""))
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.systemOrange
        stack.addArrangedSubview(label)

        return stack
    }

    // MARK: - Interactions (placeholders for Tasks 10-11)

    private func onFileSlotClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("open-target-panel-prompt", comment: "")
        panel.message = NSLocalizedString("open-target-panel-message", comment: "")
        // 不限制扩展名: 接受 .app, .sh, .py, 任意可执行文件

        guard let popoverWindow = popover?.contentViewController?.view.window else {
            // Fallback: 模态运行
            if panel.runModal() == .OK, let url = panel.url, let picked = Self.resolvePickedFile(at: url) {
                applyPickedFile(picked)
            }
            return
        }
        panel.beginSheetModal(for: popoverWindow) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            if let picked = Self.resolvePickedFile(at: url) {
                self.applyPickedFile(picked)
            }
        }
    }

    /// 解析任意文件 URL 为待保存的字段集; 返回 nil 表示路径无效.
    private static func resolvePickedFile(at url: URL) -> PickedFile? {
        var isDirectory: ObjCBool = false
        let isApp = url.pathExtension.lowercased() == "app"
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue || isApp else { return nil }
        let bundleID = isApp ? Bundle(url: url)?.bundleIdentifier : nil
        return PickedFile(path: url.path, bundleID: bundleID, isApplication: isApp)
    }

    private func applyPickedFile(_ picked: PickedFile) {
        selectedPath = picked.path
        selectedBundleID = picked.bundleID
        selectedIsApplication = picked.isApplication
        staleBanner?.isHidden = true
        applyFilledStateForCurrentSelection(animated: true)
    }

    private func applyFilledStateForCurrentSelection(animated: Bool) {
        guard let path = selectedPath else {
            fileSlot?.setState(.empty, animated: animated)
            doneButton?.isEnabled = false
            setArgumentsVisible(false, animated: animated)
            return
        }
        let url = URL(fileURLWithPath: path)
        let workspace = NSWorkspace.shared
        let icon = workspace.icon(forFile: url.path)
        let title: String = {
            if selectedIsApplication, let bundle = Bundle(url: url) {
                return bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
            }
            return url.lastPathComponent
        }()
        let content = FileSlotView.FilledContent(icon: icon, title: title, subtitle: path)
        fileSlot?.setState(.filled(content), animated: animated)
        doneButton?.isEnabled = true
        setArgumentsVisible(true, animated: animated)
    }

    private func onFileSlotCleared() {
        selectedPath = nil
        selectedBundleID = nil
        selectedIsApplication = false
        staleBanner?.isHidden = true
        fileSlot?.setState(.empty, animated: true)
        doneButton?.isEnabled = false
        setArgumentsVisible(false, animated: true)
    }

    private func setArgumentsVisible(_ visible: Bool, animated: Bool) {
        argsSectionHeightConstraint?.constant = visible ? Self.argsSectionHeight : 0
        doneButton?.isEnabled = visible && selectedPath != nil

        let updateLayout = { [weak self] in
            guard let self = self else { return }
            self.popover?.contentViewController?.view.layoutSubtreeIfNeeded()
            self.resizePopoverToFit()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                self.argsSection?.animator().alphaValue = visible ? 1 : 0
                updateLayout()
            }
        } else {
            argsSection?.alphaValue = visible ? 1 : 0
            updateLayout()
        }
    }

    private func resizePopoverToFit() {
        guard let popover = popover,
              let view = popover.contentViewController?.view else { return }
        let fittingSize = view.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }
        popover.contentSize = fittingSize
    }

    @objc private func onDoneButton() {
        guard let path = selectedPath, let argsField = argsField else { return }
        let payload = OpenTargetPayload(
            path: path,
            bundleID: selectedBundleID,
            arguments: argsField.stringValue,
            isApplication: selectedIsApplication
        )
        onCommit?(payload)
        hide()
    }

    @objc private func onCancelButton() {
        onCancel?()
        hide()
    }
}

// MARK: - File slot view (empty + filled states with crossfade)

final class FileSlotView: NSView {

    var onClick: (() -> Void)?
    var onClear: (() -> Void)?
    /// Drop callback exposed to the popover.
    var onDrop: ((URL) -> Void)?

    private(set) var state: State = .empty

    enum State: Equatable {
        case empty
        case filled(FilledContent)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty):
                return true
            case (.filled(let lhsContent), .filled(let rhsContent)):
                return lhsContent == rhsContent
            default:
                return false
            }
        }
    }

    struct FilledContent: Equatable {
        let icon: NSImage?
        let title: String
        let subtitle: String

        static func == (lhs: FilledContent, rhs: FilledContent) -> Bool {
            return lhs.icon === rhs.icon &&
                   lhs.title == rhs.title &&
                   lhs.subtitle == rhs.subtitle
        }
    }

    private var emptyView: NSView!
    private var filledView: NSView!
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        preserveFrameWhileSettingCenteredAnchorPoint()
        borderLayer.fillColor = nil
        borderLayer.lineDashPattern = [5, 4]
        layer?.addSublayer(borderLayer)
        registerForDraggedTypes([.fileURL])

        emptyView = makeEmptyView()
        filledView = makeFilledView()
        emptyView.alphaValue = 1
        filledView.alphaValue = 0
        addSubview(emptyView)
        addSubview(filledView)

        applyEmptyAppearance()
    }

    private func preserveFrameWhileSettingCenteredAnchorPoint() {
        guard let layer = layer else { return }
        let origin = frame.origin
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        frame.origin = origin
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        emptyView.frame = bounds
        filledView.frame = bounds
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Don't propagate clicks on the clear button
        let point = convert(event.locationInWindow, from: nil)
        if let clearBtn = filledView.viewWithTag(99), clearBtn.frame.contains(point), case .filled = state {
            return
        }
        onClick?()
    }

    // MARK: State control

    func setState(_ newState: State, animated: Bool = true) {
        guard newState != state else { return }
        state = newState

        let (showView, hideView): (NSView, NSView) = {
            switch newState {
            case .empty: return (emptyView, filledView)
            case .filled(let content):
                applyFilledContent(content)
                return (filledView, emptyView)
            }
        }()

        switch newState {
        case .empty: applyEmptyAppearance()
        case .filled: applyFilledAppearance()
        }

        if animated {
            showView.alphaValue = 0
            showView.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.98, y: 0.98))
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                showView.animator().alphaValue = 1
                showView.animator().layer?.setAffineTransform(.identity)
                hideView.animator().alphaValue = 0
            })
        } else {
            showView.alphaValue = 1
            showView.layer?.setAffineTransform(.identity)
            hideView.alphaValue = 0
        }
    }

    // MARK: Appearance

    fileprivate func applyEmptyAppearance() {
        borderLayer.lineWidth = 1
        borderLayer.lineDashPattern = [5, 4]
        borderLayer.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.32).cgColor
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.04).cgColor
        toolTip = NSLocalizedString("open-target-empty-tooltip", comment: "")
    }

    fileprivate func applyFilledAppearance() {
        borderLayer.lineWidth = 1
        borderLayer.lineDashPattern = [5, 4]
        borderLayer.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.24).cgColor
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.03).cgColor
        toolTip = NSLocalizedString("open-target-filled-tooltip", comment: "")
    }

    // MARK: Empty subview

    private func makeEmptyView() -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let placeholder = NSImageView()
        placeholder.image = Self.placeholderImage()
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        if #available(macOS 10.14, *) {
            placeholder.contentTintColor = NSColor.tertiaryLabelColor
        }
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let primary = NSTextField(labelWithString: NSLocalizedString("open-target-empty-primary", comment: ""))
        primary.font = NSFont.systemFont(ofSize: 13)
        primary.textColor = NSColor.labelColor

        let secondary = NSTextField(labelWithString: NSLocalizedString("open-target-empty-secondary", comment: ""))
        secondary.font = NSFont.systemFont(ofSize: 11)
        secondary.textColor = NSColor.tertiaryLabelColor

        let stack = NSStackView(views: [placeholder, primary, secondary])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            placeholder.widthAnchor.constraint(equalToConstant: 24),
            placeholder.heightAnchor.constraint(equalToConstant: 24),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private static func placeholderImage() -> NSImage? {
        if #available(macOS 11.0, *),
           let symbol = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil) {
            symbol.isTemplate = true
            return symbol
        }
        let icon = NSWorkspace.shared.icon(forFileType: "app")
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }

    // MARK: Filled subview

    private weak var filledIcon: NSImageView?
    private weak var filledTitle: NSTextField?
    private weak var filledSubtitle: NSTextField?

    private func makeFilledView() -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        self.filledIcon = icon

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.textColor = NSColor.labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        self.filledTitle = title

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = NSFont.systemFont(ofSize: 10.5)
        subtitle.textColor = NSColor.tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)
        self.filledSubtitle = subtitle

        let clearBtn = NSButton()
        clearBtn.tag = 99  // used in mouseDown hit test
        clearBtn.bezelStyle = .inline
        clearBtn.isBordered = false
        if #available(macOS 11.0, *) {
            clearBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        } else {
            clearBtn.title = "✕"
        }
        if #available(macOS 10.14, *) {
            clearBtn.contentTintColor = NSColor.tertiaryLabelColor
        }
        clearBtn.toolTip = NSLocalizedString("open-target-clear-tooltip", comment: "")
        clearBtn.target = self
        clearBtn.action = #selector(onClearClicked)
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clearBtn)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 36),
            icon.heightAnchor.constraint(equalToConstant: 36),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: clearBtn.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),

            clearBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            clearBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            clearBtn.widthAnchor.constraint(equalToConstant: 16),
            clearBtn.heightAnchor.constraint(equalToConstant: 16),
        ])

        return container
    }

    private func applyFilledContent(_ content: FilledContent) {
        filledIcon?.image = content.icon
        filledTitle?.stringValue = content.title
        filledSubtitle?.stringValue = content.subtitle
        toolTip = "\(content.subtitle)\n\(NSLocalizedString("open-target-filled-tooltip", comment: ""))"
    }

    @objc private func onClearClicked() {
        onClear?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let first = firstDraggedFileURL(sender), isAcceptedDraggedFile(first) else {
            return []
        }
        // Visual: soft accent border + center-origin scale up
        borderLayer.lineWidth = 1.2
        borderLayer.lineDashPattern = [5, 4]
        borderLayer.strokeColor = accentColor.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = accentColor.withAlphaComponent(0.05).cgColor
        animateScale(to: 1.02)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        revertDragVisual()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { revertDragVisual() }
        guard let first = firstDraggedFileURL(sender), isAcceptedDraggedFile(first) else {
            return false
        }
        onDrop?(first)
        return true
    }

    private func firstDraggedFileURL(_ sender: NSDraggingInfo) -> URL? {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return nil
        }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return nil
        }
        return urls.first
    }

    private func isAcceptedDraggedFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let isApp = url.pathExtension.lowercased() == "app"
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue || isApp
    }

    private var accentColor: NSColor {
        if #available(macOS 10.14, *) {
            return NSColor.controlAccentColor
        }
        return NSColor.alternateSelectedControlColor
    }

    private func animateScale(to scale: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        }
    }

    private func revertDragVisual() {
        animateScale(to: 1.0)
        switch state {
        case .empty: applyEmptyAppearance()
        case .filled: applyFilledAppearance()
        }
    }
}
