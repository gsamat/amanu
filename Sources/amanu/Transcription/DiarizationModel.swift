import Foundation

enum DiarizationModel: String, Codable, CaseIterable, Sendable {
    case nemotron3 = "nemotron-3"
    case lsEendAMI = "ls-eend-ami"
    case community1 = "community-1"

    static let `default`: Self = .nemotron3

    var title: String {
        switch self {
        case .nemotron3: "Nemotron 3"
        case .lsEendAMI: "LS-EEND AMI"
        case .community1: "Community-1"
        }
    }

    var detailEnglish: String {
        switch self {
        case .nemotron3: "Meetings up to 8 speakers"
        case .lsEendAMI: "Meetings up to 4 speakers"
        case .community1: "Compact alternative"
        }
    }

    var detailRussian: String {
        switch self {
        case .nemotron3: "Встречи до 8 говорящих"
        case .lsEendAMI: "Встречи до 4 говорящих"
        case .community1: "Компактная альтернатива"
        }
    }

    var advertisedBytes: Int {
        switch self {
        case .nemotron3: 107_012_128
        case .lsEendAMI: 44_674_992
        case .community1: DiarizationModelStore.advertisedBytes
        }
    }

    var revision: String {
        switch self {
        case .nemotron3: "f667ed73aee57d40cc39428eb768b4fd87a0a29e"
        case .lsEendAMI: "28ce1b1f8ef186729df63b3886fbaae7bc10c4a1"
        case .community1: DiarizationModelStore.revision
        }
    }

    var assetDirectoryName: String {
        switch self {
        case .nemotron3: "diarization-nemotron-3"
        case .lsEendAMI: "diarization-ls-eend-ami"
        case .community1: "diarization"
        }
    }

    var primaryAssetPath: String {
        switch self {
        case .nemotron3: "models/Nemotron-3-Diarization.q8_0.gguf"
        case .lsEendAMI: "optimized/ami/500ms/ls_eend_ami_500ms.mlmodelc"
        case .community1: "Segmentation.mlmodelc"
        }
    }

    var repository: String {
        switch self {
        case .nemotron3: "nvidia/Nemotron-3-Diarization"
        case .lsEendAMI: "FluidInference/ls-eend-coreml"
        case .community1: DiarizationModelStore.repository
        }
    }
}
