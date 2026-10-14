import XCTest
import UIKit
@testable import ioscloth

/// 图片读写的真实落盘测试。故意用临时目录，不碰真实沙盒。
final class ImageStoreTests: XCTestCase {

    private var root: URL!
    private var store: ImageStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ioscloth-image-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ImageStore(root: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - 写入

    func testSaveWritesMainAndThumbnailFiles() async throws {
        let id = UUID()
        let names = try await store.save(Self.makeImage(width: 2000, height: 1200), id: id)

        XCTAssertEqual(names.main, "\(id.uuidString).jpg")
        XCTAssertEqual(names.thumb, "\(id.uuidString).jpg")

        let mainPath = root.appendingPathComponent("Images/\(names.main)").path
        let thumbPath = root.appendingPathComponent("Thumbs/\(names.thumb)").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: mainPath), "主图应该落盘")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbPath), "缩略图应该落盘")
    }

    func testThumbnailIsSmallerThanMainImage() async throws {
        let names = try await store.save(Self.makeImage(width: 2000, height: 1200), id: UUID())
        let mainSize = try Self.fileSize(root.appendingPathComponent("Images/\(names.main)"))
        let thumbSize = try Self.fileSize(root.appendingPathComponent("Thumbs/\(names.thumb)"))

        XCTAssertGreaterThan(mainSize, 0)
        XCTAssertGreaterThan(thumbSize, 0)
        XCTAssertLessThan(thumbSize, mainSize, "缩略图必须比主图小，否则图墙会卡")
    }

    func testSavedImageCanBeLoadedBack() async throws {
        let names = try await store.save(Self.makeImage(width: 800, height: 600), id: UUID())
        let loaded = await store.load(named: names.main)
        XCTAssertNotNil(loaded)
    }

    func testLoadThumbnailFallsBackToMainImage() async throws {
        let names = try await store.save(Self.makeImage(width: 800, height: 600), id: UUID())
        // 故意给一个不存在的缩略图名，应该退回主图而不是返回 nil
        let loaded = await store.loadThumbnail(preferring: "does-not-exist.jpg", fallback: names.main)
        XCTAssertNotNil(loaded, "缩略图缺失时必须退回主图，图墙不该出现空洞")
    }

    func testLoadingEmptyNameReturnsNil() async {
        let loaded = await store.load(named: "")
        XCTAssertNil(loaded)
    }

    // MARK: - 删除

    func testDeleteRemovesFilesFromDisk() async throws {
        let names = try await store.save(Self.makeImage(width: 400, height: 400), id: UUID())
        await store.deleteAll(main: names.main, thumb: names.thumb, cutout: "")

        let mainPath = root.appendingPathComponent("Images/\(names.main)").path
        let thumbPath = root.appendingPathComponent("Thumbs/\(names.thumb)").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbPath))
    }

    // MARK: - 体检

    func testOrphanDetectionFindsUnreferencedFiles() async throws {
        let kept = try await store.save(Self.makeImage(width: 200, height: 200), id: UUID())
        let orphan = try await store.save(Self.makeImage(width: 200, height: 200), id: UUID())

        let known: Set<String> = [kept.main, kept.thumb]
        let orphans = await store.orphanedFiles(knownNames: known)

        XCTAssertTrue(orphans.contains(orphan.main), "没有数据库引用的文件应被识别为幽灵图片")
        XCTAssertFalse(orphans.contains(kept.main))
    }

    func testDiskUsageIncreasesAfterSave() async throws {
        let before = await store.diskUsage()
        _ = try await store.save(Self.makeImage(width: 1000, height: 1000), id: UUID())
        let after = await store.diskUsage()
        XCTAssertGreaterThan(after, before)
    }

    // MARK: - 缩放

    func testResizeKeepsAspectRatioAndCapsLongestSide() {
        let original = Self.makeImage(width: 4000, height: 2000)
        let resized = original.resized(maxDimension: 1600)
        XCTAssertEqual(resized.size.width, 1600, accuracy: 1)
        XCTAssertEqual(resized.size.height, 800, accuracy: 1)
    }

    func testResizeDoesNotUpscaleSmallImages() {
        let original = Self.makeImage(width: 100, height: 80)
        let resized = original.resized(maxDimension: 1600)
        XCTAssertEqual(resized.size.width, 100, accuracy: 1)
        XCTAssertEqual(resized.size.height, 80, accuracy: 1)
    }

    // MARK: - 辅助

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 生成一张有渐变的图（纯色压缩率太高，量不出真实体积差）
    private static func makeImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cgContext = context.cgContext
            let colors = [UIColor.systemPink.cgColor, UIColor.systemTeal.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
        }
    }
}
