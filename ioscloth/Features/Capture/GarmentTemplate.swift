import SwiftUI
import UIKit

/// 拍照模板：在相机预览上叠一个衣物轮廓，帮助把衣服摆正、摆满。
///
/// 系统没有提供任何「衣物轮廓」组件 —— VisionKit 只做证件/文稿的矩形检测。
/// 所以模板是自己用 `Path` 画的简单示意轮廓，作用是**构图引导**，不是自动抠图。
///
/// 拍完按蒙层方框自动裁成正方形，和 App 里其它地方的方形显示保持一致；
/// 想自己构图就用「自由拍照」，那条路走系统相机 + 系统裁剪。
enum GarmentTemplate: String, CaseIterable, Identifiable {
    case free
    case top
    case bottom
    case dress

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .free: "自由"
        case .top: "上衣"
        case .bottom: "下衣"
        case .dress: "连衣裙"
        }
    }

    var hint: String {
        switch self {
        case .free: "随意构图，拍完可以用系统裁剪"
        case .top: "把上衣摆进轮廓里，撑满画面"
        case .bottom: "把裤子或裙摆摆进轮廓里"
        case .dress: "把整条连衣裙摆进轮廓里"
        }
    }

    var systemImage: String {
        switch self {
        case .free: "camera"
        case .top: "tshirt"
        case .bottom: "figure.walk"
        case .dress: "figure.dress.line.vertical.figure"
        }
    }

    /// 取景框在预览里的归一化矩形。
    ///
    /// 所有模板都用同一个居中正方形，保证存下来的图尺寸一致（衣柜和搭配里都是方形卡片）。
    static func frameRect(in size: CGSize) -> CGRect {
        let side = min(size.width, size.height) * 0.86
        return CGRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side
        )
    }

    /// 屏幕上的取景框 → **照片**里的归一化矩形（0…1，原点左上）。
    ///
    /// 为什么不能用一个固定值：相机是 4:3、屏幕是 9:19.5，
    /// 预览用 `resizeAspectFill` 铺满时，画面是被**放大并居中裁过**的。
    /// 直接把屏幕框当比例用，裁出来的位置和用户看到的完全对不上
    /// （实测会裁出一个长方形而不是正方形）。
    ///
    /// 所以这里按 aspect-fill 的实际缩放换算：
    /// 缩放 = max(预览宽/照片宽, 预览高/照片高)，再反推框在照片里的位置。
    static func normalizedCropRect(photoSize: CGSize, previewSize: CGSize, frameRect: CGRect) -> CGRect {
        guard photoSize.width > 0, photoSize.height > 0,
              previewSize.width > 0, previewSize.height > 0 else { return .zero }

        let scale = max(previewSize.width / photoSize.width, previewSize.height / photoSize.height)
        let displayed = CGSize(width: photoSize.width * scale, height: photoSize.height * scale)
        let origin = CGPoint(
            x: (previewSize.width - displayed.width) / 2,
            y: (previewSize.height - displayed.height) / 2
        )

        let rect = CGRect(
            x: (frameRect.minX - origin.x) / displayed.width,
            y: (frameRect.minY - origin.y) / displayed.height,
            width: frameRect.width / displayed.width,
            height: frameRect.height / displayed.height
        )
        return rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 轮廓路径（画在取景框内部，坐标以框为参照）
    func silhouette(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        switch self {
        case .free:
            path.addRoundedRect(
                in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02),
                cornerSize: CGSize(width: 18, height: 18)
            )

        case .top:
            // 一只简化的 T 恤：躯干 + 两侧袖子
            path.move(to: point(0.32, 0.14))
            path.addLine(to: point(0.10, 0.28))
            path.addLine(to: point(0.20, 0.44))
            path.addLine(to: point(0.30, 0.36))
            path.addLine(to: point(0.30, 0.96))
            path.addLine(to: point(0.70, 0.96))
            path.addLine(to: point(0.70, 0.36))
            path.addLine(to: point(0.80, 0.44))
            path.addLine(to: point(0.90, 0.28))
            path.addLine(to: point(0.68, 0.14))
            // 领口
            path.addQuadCurve(to: point(0.32, 0.14), control: point(0.50, 0.26))
            path.closeSubpath()

        case .bottom:
            // 一条简化的长裤：腰头 + 两条腿，裆部留出明显的缺口
            path.move(to: point(0.22, 0.06))
            path.addLine(to: point(0.78, 0.06))
            path.addLine(to: point(0.76, 0.96))
            path.addLine(to: point(0.56, 0.96))
            path.addLine(to: point(0.50, 0.52))
            path.addLine(to: point(0.44, 0.96))
            path.addLine(to: point(0.24, 0.96))
            path.closeSubpath()

        case .dress:
            // 一条 A 字连衣裙
            path.move(to: point(0.40, 0.06))
            path.addLine(to: point(0.60, 0.06))
            path.addLine(to: point(0.66, 0.34))
            path.addLine(to: point(0.86, 0.96))
            path.addLine(to: point(0.14, 0.96))
            path.addLine(to: point(0.34, 0.34))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - 按蒙层裁切

extension GarmentTemplate {
    /// 把整张照片裁成蒙层框住的那块正方形。
    ///
    /// 照片先做方向归一，再按归一化矩形切开 ——
    /// 预览和照片都是竖屏，所以归一化坐标可以直接用。
    static func crop(_ image: UIImage, toNormalized rect: CGRect) -> UIImage {
        let normalized = image.upright()
        guard let cgImage = normalized.cgImage else { return normalized }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: rect.origin.x * width,
            y: rect.origin.y * height,
            width: rect.width * width,
            height: rect.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard pixelRect.width > 1, pixelRect.height > 1 else { return normalized }
        guard let cropped = cgImage.cropping(to: pixelRect) else { return normalized }
        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up)
    }
}
