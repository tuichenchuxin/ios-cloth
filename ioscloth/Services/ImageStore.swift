import Foundation
import UIKit

enum ImageStoreError: LocalizedError {
    case encodingFailed
    case fileMissing(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "图片编码失败（可能不是有效的图片数据）"
        case .fileMissing(let name): "找不到图片文件：\(name)"
        }
    }
}

/// 图片落盘。**库（SwiftData）里只存文件名，像素数据全在这里。**
///
/// 目录布局（DESIGN.md §5.1）：
/// ```
/// <沙盒>/Documents/
///   Images/<uuid>.jpg   主图，长边 1600
///   Thumbs/<uuid>.jpg   缩略图，长边 400
///   Cutouts/<uuid>.png  抠白底（M3 才用）
///   Backups/            结构化数据导出
/// ```
///
/// 用 `actor` 保证并发安全：压缩是 CPU 密集操作，不该在主线程做。
actor ImageStore {
    static let shared = ImageStore()

    /// 主图长边像素
    private let mainMaxDimension: CGFloat = 1600
    /// 缩略图长边像素
    private let thumbMaxDimension: CGFloat = 400
    private let mainQuality: CGFloat = 0.8
    private let thumbQuality: CGFloat = 0.7

    private let root: URL
    private let mainDirectory: URL
    private let thumbDirectory: URL
    private let cutoutDirectory: URL
    private let backupDirectory: URL

    init(root: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = root ?? documents
        self.root = base
        self.mainDirectory = base.appendingPathComponent("Images", isDirectory: true)
        self.thumbDirectory = base.appendingPathComponent("Thumbs", isDirectory: true)
        self.cutoutDirectory = base.appendingPathComponent("Cutouts", isDirectory: true)
        self.backupDirectory = base.appendingPathComponent("Backups", isDirectory: true)
    }

    /// 所有目录。第一次写文件前必须调一次。
    func prepareDirectories() throws {
        for directory in [mainDirectory, thumbDirectory, cutoutDirectory, backupDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - 写入

    /// 保存一件衣物的图片，返回（主图文件名, 缩略图文件名）。
    @discardableResult
    func save(_ image: UIImage, id: UUID) throws -> (main: String, thumb: String) {
        try prepareDirectories()

        let base = id.uuidString
        let mainName = "\(base).jpg"
        let thumbName = "\(base).jpg"

        // 先把方向拍平再缩放：带 orientation 标记的图如果直接按 size 缩放会算出错的尺寸
        // （相机原图、以及从相册选的原图都可能带方向标记）
        let normalized = image.upright()

        guard let mainData = normalized.resized(maxDimension: mainMaxDimension).jpegData(quality: mainQuality) else {
            throw ImageStoreError.encodingFailed
        }
        let thumbData = normalized.resized(maxDimension: thumbMaxDimension).jpegData(quality: thumbQuality) ?? mainData

        try mainData.write(to: mainDirectory.appendingPathComponent(mainName), options: .atomic)
        try thumbData.write(to: thumbDirectory.appendingPathComponent(thumbName), options: .atomic)

        return (mainName, thumbName)
    }

    // MARK: - 读取

    func load(named name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        return UIImage(contentsOfFile: url(for: name)?.path ?? "")
    }

    /// 缩略图优先，取不到就退回主图 —— 图墙永远不该出现空洞。
    func loadThumbnail(preferring thumbName: String, fallback mainName: String) -> UIImage? {
        load(named: thumbName) ?? load(named: mainName)
    }

    // MARK: - 删除与体检

    func delete(_ names: [String]) {
        for name in names where !name.isEmpty {
            guard let url = url(for: name) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 单件衣物对应的所有文件
    func deleteAll(main: String, thumb: String, cutout: String) {
        delete([main, thumb, cutout])
    }

    /// 找出磁盘上存在、但数据库里已经没有引用的「幽灵图片」
    func orphanedFiles(knownNames: Set<String>) -> [String] {
        let fileManager = FileManager.default
        var orphans: [String] = []

        for directory in [mainDirectory, thumbDirectory, cutoutDirectory] {
            let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in contents where !knownNames.contains(file) {
                orphans.append(file)
            }
        }
        return orphans.sorted()
    }

    /// 占用空间（字节）
    func diskUsage() -> Int64 {
        let fileManager = FileManager.default
        var total: Int64 = 0
        for directory in [mainDirectory, thumbDirectory, cutoutDirectory] {
            let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in contents {
                let path = directory.appendingPathComponent(file).path
                let attributes = try? fileManager.attributesOfItem(atPath: path)
                total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    func backupDirectoryURL() -> URL {
        try? prepareDirectories()
        return backupDirectory
    }

    // MARK: - 内部

    /// 按文件名路由到正确目录（主图 / 缩略图 / 抠图三处同名不冲突，各自的 id.jpg 在不同目录）
    private func url(for name: String) -> URL? {
        for directory in [mainDirectory, thumbDirectory, cutoutDirectory] {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
