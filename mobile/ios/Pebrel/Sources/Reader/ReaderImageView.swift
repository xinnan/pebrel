import SwiftUI
import UIKit

/// Interactive pinch-to-zoom (1x..8x), pan, and double-tap-reset image viewer.
struct ReaderImageView: View {
    let image: UIImage
    @Binding var resetToken: Int

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = (lastScale * value).clamped(to: 1.0...8.0)
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.01 {
                                reset()
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1.01 else { return }
                            let maxX = geo.size.width * (scale - 1) * 0.5
                            let maxY = geo.size.height * (scale - 1) * 0.5
                            offset = CGSize(
                                width: (lastOffset.width + value.translation.width).clamped(to: -maxX...maxX),
                                height: (lastOffset.height + value.translation.height).clamped(to: -maxY...maxY)
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1.01 { reset() } else { scale = 2.5; lastScale = 2.5 }
                    }
                }
                .onChange(of: resetToken) { _ in
                    withAnimation(.easeInOut(duration: 0.2)) { reset() }
                }
        }
    }

    private func reset() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
    }
}
