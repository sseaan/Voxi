import Foundation

/// 一个「来源 + 模型」组合。回退顺序由模型页的扁平列表决定（`VoxiSettings.asrOrder`）。
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
        case .aliyunBailianStreaming:
            copy.aliyun.model = model
        case .mimoASR:
            copy.mimo.model = model
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
        case .aliyunBailianStreaming:
            let manual = aliyun.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return manual.isEmpty ? [] : [manual]
        case .mimoASR:
            let manual = mimo.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return manual.isEmpty ? [] : [manual]
        }
    }
}

extension VoxiSettings {
    /// 全部启用的语音识别模型。
    ///
    /// - 有显式 `asrOrder` 时按它排序（可跨来源）；
    /// - 新增 / 未记录的模型排在末尾，旧配置（nil）按来源 × 模型推导。
    var asrCandidates: [ASRModelCandidate] {
        let derived = profiles.flatMap { profile in
            profile.effectiveModels.map { ASRModelCandidate(profile: profile, model: $0) }
        }
        guard let asrOrder, !asrOrder.isEmpty else { return derived }

        var byID: [String: ASRModelCandidate] = [:]
        for candidate in derived { byID[candidate.id] = candidate }

        var seen = Set<String>()
        var ordered: [ASRModelCandidate] = []
        for id in asrOrder {
            guard let candidate = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(candidate)
        }
        for candidate in derived where !seen.contains(candidate.id) {
            ordered.append(candidate)
        }
        return ordered
    }
}
