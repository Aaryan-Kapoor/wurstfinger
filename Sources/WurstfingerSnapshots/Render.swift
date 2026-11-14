//
//  Render.swift
//  WurstfingerSnapshots
//
//  SwiftUI view in, PNG out.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One image the tool produces: a view, the size to render it at, and the
/// appearance to render it in.
struct Shot {
    var size: CGSize
    var scheme: ColorScheme = .light
    var content: AnyView
    /// Render through a real (off-screen) window instead of `ImageRenderer`.
    /// `ImageRenderer` draws scroll views, lists and forms as placeholders,
    /// since SwiftUI backs them with AppKit views; the app's own screens
    /// need this path.
    var hosted = false
    /// Objects the view only holds weakly (a trail's owner token) and the
    /// scenario's view model: kept here until the render is done.
    var keepAlive: [AnyObject] = []
}

struct RenderedImage {
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
}

enum RenderError: Error, CustomStringConvertible {
    case noImage
    case wrongSize(expected: CGSize, actual: CGSize)
    case blank
    case cannotWrite(String)

    var description: String {
        switch self {
        case .noImage: "ImageRenderer produced no image"
        case let .wrongSize(expected, actual):
            "image is \(Int(actual.width))x\(Int(actual.height)) px, expected \(Int(expected.width))x\(Int(expected.height))"
        case .blank: "image is a single flat colour (nothing rendered)"
        case let .cannotWrite(message): "cannot write PNG: \(message)"
        }
    }
}

@MainActor
enum Renderer {
    /// Renders `shot` at `scale` pixels per point and writes it to `url`.
    static func writePNG(_ shot: Shot, scale: CGFloat, to url: URL) throws -> RenderedImage {
        // Round the canvas up to whole pixels: a fractional height (a keyboard
        // clamped to a landscape screen) would leave a one-pixel strip the
        // renderer fills with black.
        var shot = shot
        shot.size = CGSize(
            width: (shot.size.width * scale).rounded(.up) / scale,
            height: (shot.size.height * scale).rounded(.up) / scale
        )
        let background = Color(nsColor: shot.scheme == .dark ? .black : .white)
        let content = ZStack {
            background
            shot.content
        }
        .frame(width: shot.size.width, height: shot.size.height)
        .environment(\.colorScheme, shot.scheme)

        let rendered: CGImage?
        if shot.hosted {
            rendered = hostedImage(of: content, size: shot.size, scheme: shot.scheme, scale: scale)
        } else {
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            renderer.proposedSize = ProposedViewSize(shot.size)
            renderer.isOpaque = true
            rendered = renderer.cgImage
        }
        guard let image = rendered else { throw RenderError.noImage }

        let expected = CGSize(
            width: (shot.size.width * scale).rounded(), height: (shot.size.height * scale).rounded()
        )
        let actual = CGSize(width: image.width, height: image.height)
        guard abs(actual.width - expected.width) <= 1, abs(actual.height - expected.height) <= 1 else {
            throw RenderError.wrongSize(expected: expected, actual: actual)
        }
        guard !isFlat(image) else { throw RenderError.blank }

        let bytes = try encodePNG(image)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw RenderError.cannotWrite("\(error)")
        }
        return RenderedImage(pixelWidth: image.width, pixelHeight: image.height, byteCount: bytes.count)
    }

    /// Puts `content` in an off-screen window, lets SwiftUI run its appearance
    /// and layout passes (`onAppear` handlers included), and draws the window's
    /// content view into a bitmap of `scale` pixels per point.
    private static func hostedImage(of content: some View, size: CGSize, scheme: ColorScheme, scale: CGFloat) -> CGImage? {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        // Give SwiftUI a few passes: the first lays the tree out, and state
        // set in `onAppear` shows up in the next.
        for _ in 0 ..< 6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        host.layoutSubtreeIfNeeded()

        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // The representation's point size stays `size`, so the view draws
        // scaled up into the larger pixel grid, not magnified afterwards.
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        return bitmap.cgImage
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw RenderError.cannotWrite("no PNG encoder") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.cannotWrite("encoding failed") }
        return data as Data
    }

    /// Whether every sampled pixel is the same colour — the signature of a
    /// view that failed to render and left only the background.
    private static func isFlat(_ image: CGImage) -> Bool {
        let width = min(image.width, 200), height = min(image.height, 200)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let first = pixels[0 ..< 4]
        for index in stride(from: 4, to: pixels.count, by: 4) where pixels[index ..< index + 4] != first {
            return false
        }
        return true
    }
}
