//
//  ActionDisplayRenderer.swift
//  Mos
//
//  Created by Mos on 2026/4/12.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

struct ActionDisplayRenderer {

    func render(_ presentation: ActionPresentation, into popupButton: NSPopUpButton) {
        guard let menu = popupButton.menu,
              let placeholderItem = menu.items.first else {
            return
        }

        switch presentation.kind {
        case .unbound, .recordingPrompt:
            apply(title: presentation.title, image: nil, placeholderItem: placeholderItem, popupButton: popupButton)

        case .namedAction:
            let baseImage = createSymbolImage(named: presentation.symbolName)
            let finalImage = prefixedImageIfNeeded(baseImage, brand: presentation.brand)
            apply(title: presentation.title, image: finalImage, placeholderItem: placeholderItem, popupButton: popupButton)

        case .keyCombo:
            let badgeImage = Self.createBadgeImage(from: presentation.badgeComponents)
            let finalImage = prefixedImageIfNeeded(badgeImage, brand: presentation.brand)
            apply(title: presentation.title, image: finalImage, placeholderItem: placeholderItem, popupButton: popupButton)

        case .openTarget:
            let resizedImage = presentation.image.map { Self.resizeForBadge($0) }
            apply(title: presentation.title, image: resizedImage, placeholderItem: placeholderItem, popupButton: popupButton)
        }
    }

    /// Resize an arbitrary NSImage to match the visual size of system shortcut icons (badge height 17pt).
    private static func resizeForBadge(_ image: NSImage) -> NSImage {
        let badgeHeight: CGFloat = 17
        let originalSize = image.size
        guard originalSize.height > 0 else { return image }
        let scale = badgeHeight / originalSize.height
        let newSize = NSSize(width: originalSize.width * scale, height: badgeHeight)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .sourceOver,
                   fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    private func apply(
        title: String,
        image: NSImage?,
        placeholderItem: NSMenuItem,
        popupButton: NSPopUpButton
    ) {
        placeholderItem.title = title
        placeholderItem.image = image.map(Self.menuAlignedImage)
        popupButton.imagePosition = .imageLeft
        popupButton.selectItem(at: 0)
        popupButton.synchronizeTitleAndSelectedItem()
    }

    private static func menuAlignedImage(_ image: NSImage) -> NSImage {
        let targetHeight: CGFloat = 18
        let imageSize = image.size
        guard imageSize.height > 0, imageSize.height <= targetHeight else { return image }

        let alignedSize = NSSize(width: imageSize.width, height: targetHeight)
        let alignedImage = NSImage(size: alignedSize)
        alignedImage.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: (targetHeight - imageSize.height) / 2, width: imageSize.width, height: imageSize.height),
            from: NSRect(origin: .zero, size: imageSize),
            operation: .sourceOver,
            fraction: 1.0
        )
        alignedImage.unlockFocus()
        alignedImage.isTemplate = image.isTemplate
        return alignedImage
    }

    private func createSymbolImage(named symbolName: String?) -> NSImage? {
        guard let symbolName else { return nil }
        guard #available(macOS 11.0, *) else { return nil }
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        return createImageWithTrailingSpace(symbol)
    }

    private func prefixedImageIfNeeded(_ image: NSImage?, brand: BrandTagConfig?) -> NSImage? {
        guard let brand else { return image }
        return BrandTag.createPrefixedImage(brand: brand, original: image)
    }

    private func createImageWithTrailingSpace(_ originalImage: NSImage) -> NSImage {
        let spacing: CGFloat = 2.0
        let originalSize = originalImage.size
        let newSize = NSSize(width: originalSize.width + spacing, height: originalSize.height)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: originalSize.width, height: originalSize.height),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .sourceOver,
            fraction: 1.0
        )
        newImage.unlockFocus()
        newImage.isTemplate = originalImage.isTemplate
        return newImage
    }

    static func createBadgeImage(from components: [String]) -> NSImage {
        let fontSize: CGFloat = 9
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let plusFont = NSFont.systemFont(ofSize: fontSize)
        let badgeHeight: CGFloat = 17
        let cornerRadius: CGFloat = 3
        let hPadding: CGFloat = 5
        let plusSpacing: CGFloat = 3
        let iconSize: CGFloat = 11
        let iconTrailingGap: CGFloat = 4

        struct BadgeMetrics {
            let text: String
            let textSize: NSSize
            let badgeWidth: CGFloat
        }

        var badges: [BadgeMetrics] = []
        var totalWidth: CGFloat = 0

        for (index, component) in components.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let textSize = (component as NSString).size(withAttributes: attrs)
            let badgeWidth = max(textSize.width + hPadding * 2, badgeHeight)
            badges.append(BadgeMetrics(text: component, textSize: textSize, badgeWidth: badgeWidth))
            totalWidth += badgeWidth
            if index > 0 {
                let plusSize = ("+" as NSString).size(withAttributes: [.font: plusFont])
                totalWidth += plusSpacing * 2 + plusSize.width
            }
        }

        var iconWidth: CGFloat = 0
        if #available(macOS 11.0, *) {
            iconWidth = iconSize + iconTrailingGap
        }
        totalWidth += iconWidth

        let imageSize = NSSize(width: ceil(totalWidth) + 6, height: badgeHeight)
        return NSImage(size: imageSize, flipped: false) { _ in
            var x: CGFloat = 0

            if #available(macOS 11.0, *),
               let symbol = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
                let configured = symbol.withSymbolConfiguration(config) ?? symbol
                let symbolSize = configured.size
                let iconY = (badgeHeight - symbolSize.height) / 2
                let iconRect = NSRect(x: x, y: iconY, width: symbolSize.width, height: symbolSize.height)
                configured.draw(in: iconRect)
                NSColor.secondaryLabelColor.set()
                iconRect.fill(using: .sourceAtop)
                x += symbolSize.width + iconTrailingGap
            }

            let bgColor = Utils.isDarkMode(for: nil)
                ? NSColor(calibratedWhite: 0.5, alpha: 0.2)
                : NSColor(calibratedWhite: 0.0, alpha: 0.1)
            let textColor = NSColor.labelColor

            for (index, badge) in badges.enumerated() {
                if index > 0 {
                    let plusAttrs: [NSAttributedString.Key: Any] = [
                        .font: plusFont,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                    let plusSize = ("+" as NSString).size(withAttributes: plusAttrs)
                    x += plusSpacing
                    let plusY = (badgeHeight - plusSize.height) / 2
                    ("+" as NSString).draw(at: NSPoint(x: x, y: plusY), withAttributes: plusAttrs)
                    x += plusSize.width + plusSpacing
                }

                let badgeRect = NSRect(x: x, y: 0, width: badge.badgeWidth, height: badgeHeight)
                let path = NSBezierPath(roundedRect: badgeRect, xRadius: cornerRadius, yRadius: cornerRadius)
                bgColor.setFill()
                path.fill()

                let textAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                ]
                let textX = x + (badge.badgeWidth - badge.textSize.width) / 2
                let textY = (badgeHeight - badge.textSize.height) / 2
                (badge.text as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: textAttrs)

                x += badge.badgeWidth
            }
            return true
        }
    }
}
