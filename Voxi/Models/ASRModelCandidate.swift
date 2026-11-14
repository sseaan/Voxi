import Foundation

/// 一个「来源 + 模型」组合。同一来源可以启用多个模型，按来源顺序、模型顺序回退。
struct ASRModelCandidate: Identifiable, Equatable {
    let profile: EndpointProfile
    let model: String

    var id: String { "\(profile.id.uuidString)#\(model)" }
    var sourceName: String { profile.name.isEmpty ? profile.kind.displayName : profile.name }

    /// 复制 profile 并把模型字段替换为该候选模型。
    var resolvedProfile: EndpointProfile {
        profile.resolved(for: model)
    }
}

extension EndpointProfile {
    /// 复制 profile 并替换模型字段。
    func resolved(for model: String) -> EndpointProfile {
        var copy = self
        switch copy.kind {
        case .openAICompatible:
            copy.openAI.model = model
        case .volcengineStreaming:
            copy.volcengine.modelName = model
        }
        return copy
    }

    /// 勾选的多模型优先；否则使用手动填写的单模型。
    var effectiveModels: [String] {
        switch kind {
        case .openAICompatible:
            let values = (openAI.enabledModels ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty {
                var seen = Set<String>()
                return values.filter { seen.insert($0).inserted }
            }
            let manual = openAI.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return manual.isEmpty ? [] : [manual]
        case .volcengineStreaming:
            let manual = volcengine.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            return manual.isEmpty ? [] : [manual]
        }
    }
}

extension VoxiSettings {
    /// 按来源顺序展开所有启用的语音识别模型。
    var asrCandidates: [ASRModelCandidate] {
        profiles.flatMap { profile in
            profile.effectiveModels.map { ASRModelCandidate(profile: profile, model: $0) }
        }
    }
}
