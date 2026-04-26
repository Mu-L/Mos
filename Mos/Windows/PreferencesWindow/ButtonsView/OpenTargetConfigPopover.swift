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
    private weak var argsField: NSTextField?
    private weak var doneButton: NSButton?

    // Layout constants
    private static let contentWidth: CGFloat = 320
    private static let padding: CGFloat = 16
    private static let slotHeight: CGFloat = 64

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

        // File slot (empty state for now; filled state in Task 10)
        let slot = FileSlotView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.onClick = { [weak self] in self?.onFileSlotClicked() }
        container.addSubview(slot)
        self.fileSlot = slot

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
        container.addSubview(captionStack)

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
        container.addSubview(args)
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

        // Layout
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth + Self.padding * 2),

            slot.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            slot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            slot.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            slot.heightAnchor.constraint(equalToConstant: Self.slotHeight),

            captionStack.topAnchor.constraint(equalTo: slot.bottomAnchor, constant: 12),
            captionStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),

            args.topAnchor.constraint(equalTo: captionStack.bottomAnchor, constant: 6),
            args.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            args.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            args.heightAnchor.constraint(equalToConstant: 26),

            done.topAnchor.constraint(equalTo: args.bottomAnchor, constant: 16),
            done.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            done.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),

            cancel.topAnchor.constraint(equalTo: done.topAnchor),
            cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
        ])

        vc.view = container
        return vc
    }

    // MARK: - Interactions (placeholders for Tasks 10-11)

    private func onFileSlotClicked() {
        // Real NSOpenPanel handler arrives in Task 11
        NSLog("OpenTargetConfigPopover: file slot clicked (NSOpenPanel TODO)")
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

// MARK: - File slot view (skeleton — empty state only for Task 9)

final class FileSlotView: NSView {

    var onClick: (() -> Void)?

    private let primaryLabel = NSTextField(labelWithString: NSLocalizedString("open-target-empty-primary", comment: ""))
    private let secondaryLabel = NSTextField(labelWithString: NSLocalizedString("open-target-empty-secondary", comment: ""))

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
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5).cgColor
        // Dashed border via a CAShapeLayer overlay would be fancier; for skeleton, solid is acceptable.
        // We'll upgrade to dashed in Task 10.
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.04).cgColor

        toolTip = NSLocalizedString("open-target-empty-tooltip", comment: "")

        let stack = NSStackView(views: [primaryLabel, secondaryLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        primaryLabel.font = NSFont.systemFont(ofSize: 13)
        primaryLabel.textColor = NSColor.labelColor
        secondaryLabel.font = NSFont.systemFont(ofSize: 11)
        secondaryLabel.textColor = NSColor.tertiaryLabelColor

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Hover cursor
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
