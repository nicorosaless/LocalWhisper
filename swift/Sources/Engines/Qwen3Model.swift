import Foundation
import MLX

/// Top-level Qwen3-ASR model: audio tower + Qwen3 text decoder.
class Qwen3ASRModel {
    let config: Qwen3ASRConfig
    let audioTower: AudioTower
    let textDecoder: TextDecoder
    let tokenizer: Qwen3Tokenizer

    // Special token IDs (Qwen2-based)
    let imStartId: Int32 = 151644
    let imEndId: Int32   = 151645
    let audioStartId: Int32 = 151669
    let audioEndId: Int32   = 151670
    let audioPadId: Int32   = 151676

    init(directory: URL) throws {
        let configPath = directory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configPath)
        self.config = try JSONDecoder().decode(Qwen3ASRConfig.self, from: configData)

        self.tokenizer = try Qwen3Tokenizer(directory: directory)

        let ac = config.thinkerConfig.audioConfig
        let tc = config.thinkerConfig.textConfig

        self.audioTower = AudioTower(
            dModel: ac.dModel,
            numHeads: ac.encoderAttentionHeads,
            ffnDim: ac.encoderFfnDim,
            numLayers: ac.encoderLayers,
            nMels: ac.numMelBins
        )

        // Override proj2 output dim to match text hidden size
        let audioOutDim = tc.hiddenSize
        self.audioTower.proj2.weight = MLX.zeros([audioOutDim, ac.dModel], type: Float.self)
        self.audioTower.proj2.bias   = MLX.zeros([audioOutDim], type: Float.self)

        self.textDecoder = TextDecoder(
            hiddenSize: tc.hiddenSize,
            numHeads: tc.numAttentionHeads,
            numKVHeads: tc.numKeyValueHeads,
            headDim: tc.headDim,
            numLayers: tc.numHiddenLayers,
            vocabSize: tc.vocabSize,
            ropeTheta: Float(tc.ropeTheta)
        )

        try loadWeights(from: directory)
    }

    // Shared mel extractor instance (reused across transcriptions)
    private lazy var melExtractor = MelSpectrogram(
        sampleRate: 16000, nFft: 400, hopLength: 160, nMels: 128
    )

    /// Transcribe raw float audio samples (16kHz, mono).
    func transcribe(samples: [Float], language: String) throws -> String {
        // 1. Extract mel spectrogram
        let mel = melExtractor.extract(samples: samples)
        guard !mel.isEmpty else {
            throw ModelError.invalidAudio
        }

        let melFlat = mel.flatMap { $0 }
        let T = mel.count
        let nMels = mel[0].count
        let melArray = MLXArray(melFlat).reshaped([T, nMels])

        // 2. Encode audio -> [numAudioTokens, textHiddenSize]
        let audioFeatures = audioTower.forward(melArray)
        MLX.eval(audioFeatures)
        NSLog("[Qwen3Model] audioFeatures shape: \(audioFeatures.shape), ndim=\(audioFeatures.ndim)")
        guard audioFeatures.ndim >= 1 else {
            NSLog("[Qwen3Model] ❌ audioFeatures is 0-dim — audio tower returned scalar!")
            throw ModelError.invalidAudio
        }
        let numAudioTokens = audioFeatures.shape[0]

        // 3. Build prompt token IDs using chat template:
        //    <|im_start|>system\n<system_content><|im_end|>\n
        //    <|im_start|>user\n<|audio_start|>[audio_pad * N]<|audio_end|><|im_end|>\n
        //    <|im_start|>assistant\n
        let systemText = "Transcribe speech to text. Output language: \(language)."
        let systemTokenIds: [Int32] = tokenizer.encode(systemText).map { Int32($0) }
        let systemHeaderIds = tokenizer.encodeToInt32("system\n")
        let userHeaderIds = tokenizer.encodeToInt32("user\n")
        let assistantHeaderIds = tokenizer.encodeToInt32("assistant\n")
        let newlineIds = tokenizer.encodeToInt32("\n")

        var promptIds: [Int32] = []
        promptIds += [imStartId] + systemHeaderIds + systemTokenIds + [imEndId]
        promptIds += newlineIds
        promptIds += [imStartId] + userHeaderIds
        promptIds += [audioStartId]
        promptIds += [Int32](repeating: audioPadId, count: numAudioTokens)
        promptIds += [audioEndId, imEndId]
        promptIds += newlineIds
        promptIds += [imStartId] + assistantHeaderIds

        // 4. Embed prompt tokens
        var embeddings = textDecoder.embed(promptIds)  // [S, hiddenSize]
        MLX.eval(embeddings)

        // Replace audio_pad embeddings with audio tower features
        if let audioStartPos = promptIds.firstIndex(of: audioStartId) {
            let insertStart = audioStartPos + 1
            let insertEnd = insertStart + numAudioTokens
            var parts: [MLXArray] = []
            if insertStart > 0 {
                parts.append(embeddings[0..<insertStart, 0...])
            }
            parts.append(audioFeatures)
            if insertEnd < promptIds.count {
                parts.append(embeddings[insertEnd..., 0...])
            }
            embeddings = MLX.concatenated(parts, axis: 0)
        }

        // 5. Prefill: run full prompt through decoder to populate KV caches
        let numLayers = config.thinkerConfig.textConfig.numHiddenLayers
        let kvCaches = (0..<numLayers).map { _ in GQAKVCache() }

        var logits = textDecoder.forward(embeddings, kvCaches: kvCaches, offset: 0)
        MLX.eval(logits)

        // Guard against degenerate logits from GPU
        guard logits.ndim >= 2 else {
            NSLog("[Qwen3Model] ❌ prefill logits are degenerate (ndim=\(logits.ndim)) — aborting")
            throw ModelError.invalidAudio
        }

        // 6. Autoregressive decode
        let maxNewTokens = 512
        var generatedIds: [Int] = []
        let lastIdx = logits.shape[0] - 1
        var nextToken = argmaxInt(logits[lastIdx, 0...])
        var currentOffset = promptIds.count

        for _ in 0..<maxNewTokens {
            if nextToken == Int(imEndId) || nextToken == tokenizer.eosTokenId { break }
            generatedIds.append(nextToken)

            let tokenEmbed = textDecoder.embed([Int32(nextToken)])
            logits = textDecoder.forward(tokenEmbed, kvCaches: kvCaches, offset: currentOffset)
            MLX.eval(logits)
            guard logits.ndim >= 2 else { break }
            nextToken = argmaxInt(logits[0, 0...])
            currentOffset += 1
        }

        return tokenizer.decode(generatedIds)
    }

    // MARK: - Weight loading

    private func loadWeights(from directory: URL) throws {
        // Support single-file or sharded safetensors
        let indexPath = directory.appendingPathComponent("model.safetensors.index.json")
        var weights: [String: MLXArray]

        if FileManager.default.fileExists(atPath: indexPath.path) {
            weights = try loadShardedSafetensors(directory: directory, indexPath: indexPath)
        } else {
            let singlePath = directory.appendingPathComponent("model.safetensors")
            guard FileManager.default.fileExists(atPath: singlePath.path) else {
                throw ModelError.weightsNotFound(singlePath.path)
            }
            weights = try loadSafetensors(singlePath)
        }

        audioTower.loadWeights(weights)
        textDecoder.loadWeights(weights)
    }

    private func loadShardedSafetensors(directory: URL, indexPath: URL) throws -> [String: MLXArray] {
        let indexData = try Data(contentsOf: indexPath)
        guard let indexJson = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let weightMap = indexJson["weight_map"] as? [String: String] else {
            throw ModelError.invalidWeightsFormat
        }

        // Collect unique shard filenames
        let shards = Set(weightMap.values)
        var combined: [String: MLXArray] = [:]
        for shard in shards {
            let shardPath = directory.appendingPathComponent(shard)
            let shardWeights = try loadSafetensors(shardPath)
            combined.merge(shardWeights) { _, new in new }
        }
        return combined
    }

    private func loadSafetensors(_ url: URL) throws -> [String: MLXArray] {
        let data = try Data(contentsOf: url)
        var offset = 0

        guard data.count >= 8 else { throw ModelError.invalidWeightsFormat }
        let headerSize = data.withUnsafeBytes { ptr -> UInt64 in
            ptr.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
        }
        offset = 8

        let headerEnd = offset + Int(headerSize)
        guard headerEnd <= data.count else { throw ModelError.invalidWeightsFormat }
        let headerData = data.subdata(in: offset..<headerEnd)
        guard let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw ModelError.invalidWeightsFormat
        }
        offset = headerEnd

        var weights: [String: MLXArray] = [:]

        for (key, value) in header {
            guard key != "__metadata__",
                  let info = value as? [String: Any],
                  let dtype = info["dtype"] as? String,
                  let shape = info["shape"] as? [Int],
                  let dataOffsets = info["data_offsets"] as? [Int],
                  dataOffsets.count == 2 else { continue }

            let startOffset = offset + dataOffsets[0]
            let endOffset = offset + dataOffsets[1]
            guard endOffset <= data.count else { continue }

            let tensorData = data.subdata(in: startOffset..<endOffset)
            if let arr = makeTensor(from: tensorData, shape: shape, dtype: dtype) {
                weights[key] = arr
            }
        }

        return weights
    }

    private func makeTensor(from data: Data, shape: [Int], dtype: String) -> MLXArray? {
        switch dtype {
        case "F32":
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return shape.isEmpty ? MLXArray(floats[0]) : MLXArray(floats).reshaped(shape)
        case "BF16":
            let floats = bf16ToFloat(data)
            return shape.isEmpty ? MLXArray(floats[0]) : MLXArray(floats).reshaped(shape)
        case "F16":
            let floats = fp16ToFloat(data)
            return shape.isEmpty ? MLXArray(floats[0]) : MLXArray(floats).reshaped(shape)
        case "U32":
            let u32s = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            return MLXArray(u32s).reshaped(shape)
        case "I32":
            let i32s = data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
            return MLXArray(i32s).reshaped(shape)
        default:
            return nil
        }
    }

    private func bf16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { ptr in
            let u16 = ptr.bindMemory(to: UInt16.self)
            for i in 0..<count {
                let bits = UInt32(u16[i]) << 16
                floats[i] = Float(bitPattern: bits)
            }
        }
        return floats
    }

    private func fp16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { ptr in
            let u16 = ptr.bindMemory(to: UInt16.self)
            for i in 0..<count {
                let bits = u16[i]
                let sign: Float = (bits >> 15) == 0 ? 1 : -1
                let exp = Int((bits >> 10) & 0x1F)
                let mantissa = bits & 0x3FF
                if exp == 0 {
                    floats[i] = sign * pow(2, -14) * Float(mantissa) / 1024.0
                } else if exp == 31 {
                    floats[i] = mantissa == 0 ? sign * Float.infinity : Float.nan
                } else {
                    floats[i] = sign * pow(2, Float(exp) - 15) * (1 + Float(mantissa) / 1024.0)
                }
            }
        }
        return floats
    }

    private func argmaxInt(_ arr: MLXArray) -> Int {
        let idx = MLX.argMax(arr, axis: -1)
        return Int(idx.item(Int32.self))
    }
}

// MARK: - Config structs

struct Qwen3ASRConfig: Codable {
    let thinkerConfig: ThinkerConfig

    enum CodingKeys: String, CodingKey {
        case thinkerConfig = "thinker_config"
    }
}

struct ThinkerConfig: Codable {
    let audioConfig: AudioConfig
    let textConfig: TextConfig

    enum CodingKeys: String, CodingKey {
        case audioConfig = "audio_config"
        case textConfig = "text_config"
    }
}

struct AudioConfig: Codable {
    let dModel: Int
    let encoderAttentionHeads: Int
    let encoderFfnDim: Int
    let encoderLayers: Int
    let numMelBins: Int

    enum CodingKeys: String, CodingKey {
        case dModel = "d_model"
        case encoderAttentionHeads = "encoder_attention_heads"
        case encoderFfnDim = "encoder_ffn_dim"
        case encoderLayers = "encoder_layers"
        case numMelBins = "num_mel_bins"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dModel = try c.decodeIfPresent(Int.self, forKey: .dModel) ?? 896
        encoderAttentionHeads = try c.decodeIfPresent(Int.self, forKey: .encoderAttentionHeads) ?? 14
        encoderFfnDim = try c.decodeIfPresent(Int.self, forKey: .encoderFfnDim) ?? 3584
        encoderLayers = try c.decodeIfPresent(Int.self, forKey: .encoderLayers) ?? 18
        numMelBins = try c.decodeIfPresent(Int.self, forKey: .numMelBins) ?? 128
    }
}

struct TextConfig: Codable {
    let hiddenSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let headDim: Int
    let intermediateSize: Int
    let vocabSize: Int
    let ropeTheta: Double

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case intermediateSize = "intermediate_size"
        case vocabSize = "vocab_size"
        case ropeTheta = "rope_theta"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try c.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 1024
        numHiddenLayers = try c.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? 28
        numAttentionHeads = try c.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? 16
        numKeyValueHeads = try c.decodeIfPresent(Int.self, forKey: .numKeyValueHeads) ?? 8
        headDim = try c.decodeIfPresent(Int.self, forKey: .headDim) ?? 128
        intermediateSize = try c.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 3072
        vocabSize = try c.decodeIfPresent(Int.self, forKey: .vocabSize) ?? 151936
        ropeTheta = try c.decodeIfPresent(Double.self, forKey: .ropeTheta) ?? 1000000
    }
}

enum ModelError: Error, LocalizedError {
    case weightsNotFound(String)
    case invalidWeightsFormat
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .weightsNotFound(let path): return "Model weights not found: \(path)"
        case .invalidWeightsFormat: return "Invalid model weights format"
        case .invalidAudio: return "Invalid or empty audio"
        }
    }
}
