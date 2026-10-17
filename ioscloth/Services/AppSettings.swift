import Foundation

/// 用户偏好的存储键。
///
/// 这里只放**键名和默认值**，读写由各视图用 `@AppStorage` 完成 ——
/// 不引入额外的状态层，避免第二个「事实来源」。
enum AppSettings {
    /// 拍照/选图后自动去背景
    static let autoRemoveBackgroundKey = "autoRemoveBackground"
    static let autoRemoveBackgroundDefault = true
}
