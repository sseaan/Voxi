import SwiftUI

/// 渠道图标：优先使用 Assets 中的官方品牌图标，未知渠道回落到通用 SF Symbol。
struct ChannelIcon: View {
    /// 语言模型渠道（决定默认资产与读屏名称）。
    var vendor: ModelVendor = .custom
    /// 直接指定资产名，用于 ASR 渠道（火山 / 百炼）。
    var assetName: String? = nil
    var fallbackSymbol: String = "cloud.fill"
    var size: CGFloat = 28
    var colors: [Color] = [
        Color(red: 0.32, green: 0.55, blue: 0.98),
        Color(red: 0.20, green: 0.36, blue: 0.90)
    ]
    /// 读屏名称；nil 时使用 `vendor.displayName`。
    var accessibilityText: String? = nil

    private var resolvedAsset: String? { assetName ?? vendor.assetName }

    var body: some View {
        if let asset = resolvedAsset {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * 0.16)
                .frame(width: size, height: size)
                .background(
                    Color.white,
                    in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .accessibilityLabel(accessibilityText ?? vendor.displayName)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(
                    LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                )
                .accessibilityLabel(accessibilityText ?? vendor.displayName)
        }
    }
}
