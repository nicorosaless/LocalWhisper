import Foundation
import MLX
import MLXNN

class Qwen3ASRModel {
    let config: Qwen3Config
    let audioEncoder: AudioEncoder
    let textDecoder: TextDecoder
    let projector: Projector
    let tokenizer: Qwen3Tokenizer
    let melExtractor: MelSpectrogram
    private var kvCache: KVCache
    
    private var cachedAudioFeatures: MLXArray?
    
    init(directory: URL) throws {
        let configPath = directory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configPath)
        self.config = try JSONDecoder().decode(Qwen3Config.self, from: configData)
        
        self.tokenizer = try Qwen3Tokenizer(directory: directory)
        self.melExtractor = MelSpectrogram(
            sampleRate: 16000,
            nFft: 400,
            hopLength: 160,
            nMels: 128
        )
        
        self.audioEncoder = AudioEncoder(config: config.audioEncoderConfig)
        self.textDecoder = TextDecoder(config: config.textDecoderConfig)
        self.projector = Projector(
            inputDim: config.audioEncoderConfig.hiddenSize,
            outputDim: config.textDecoderConfig.hiddenSize
        )
        
        self.kvCache = KVCache(maxLayers: config.textDecoderConfig.numLayers)
        
        try loadWeights(from: directory)
    }
    
    func transcribe(samples: [Float], language: String) throws -> String {
        // Clear KV cache for new transcription
        kvCache.clear()
        
        // Extract mel features
        let melSpec = melExtractor.extract(samples: samples)
        let melArray = array2DToMLX(melSpec)
        
        // Encode audio (one-time)
        let audioFeatures = audioEncoder.forward(melArray)
        let projectedFeatures = projector.forward(audioFeatures)
        cachedAudioFeatures = projectedFeatures
        
        // Initialize with BOS token
        var inputIds = [tokenizer.bosTokenId]
        var generatedIds: [Int] = []
        
        // Incremental decoding with KV cache
        for step in 0..<config.maxGenerationLength {
            // Only pass the last token (rest is in KV cache)
            let lastTokenId = inputIds.last!
            let inputArray = MLXArray([Int32(lastTokenId)])
            
            let logits = textDecoder.forwardIncremental(
                inputArray,
                encoderHidden: projectedFeatures,
                kvCache: kvCache,
                step: step
            )
            
            let nextTokenId = argmax(logits)
            
            if nextTokenId == tokenizer.eosTokenId {
                break
            }
            
            generatedIds.append(nextTokenId)
            inputIds.append(nextTokenId)
        }
        
        return tokenizer.decode(generatedIds)
    }
    
    private func argmax(_ array: MLXArray) -> Int {
        let maxIdx = MLX.argMax(array, axis: -1)
        return Int(maxIdx.item(Int.self))
    }
    
    private func loadWeights(from directory: URL) throws {
        let modelFile = directory.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw ModelError.weightsNotFound(modelFile.path)
        }
        
        let weights = try loadSafetensors(modelFile)
        
        audioEncoder.loadWeights(weights, prefix: "audio_encoder.")
        textDecoder.loadWeights(weights, prefix: "text_decoder.")
        projector.loadWeights(weights, prefix: "projector.")
    }
    
    private func loadSafetensors(_ url: URL) throws -> [String: MLXArray] {
        let data = try Data(contentsOf: url)
        var offset = 0
        
        let headerSize = data.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self) }
        offset = 8
        
        let headerData = data.subdata(in: offset..<offset + Int(headerSize))
        guard let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw ModelError.invalidWeightsFormat
        }
        
        offset += Int(headerSize)
        
        var weights: [String: MLXArray] = [:]
        
        for (key, value) in header {
            guard key != "__metadata__",
                  let info = value as? [String: Any],
                  let dtype = info["dtype"] as? String,
                  let shape = info["shape"] as? [Int],
                  let dataOffsets = info["data_offsets"] as? [Int] else {
                continue
            }
            
            let startOffset = offset + dataOffsets[0]
            let endOffset = offset + dataOffsets[1]
            let tensorData = data.subdata(in: startOffset..<endOffset)
            
            let mlxArray = try createMLXArray(from: tensorData, shape: shape, dtype: dtype)
            weights[key] = mlxArray
        }
        
        return weights
    }
    
    private func createMLXArray(from data: Data, shape: [Int], dtype: String) throws -> MLXArray {
        switch dtype {
        case "F32", "FP32":
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return MLXArray(floats).reshaped(shape)
        case "BF16":
            let rawBytes = [UInt8](data)
            let floats = bf16ToFloat(rawBytes)
            return MLXArray(floats).reshaped(shape)
        case "F16", "FP16":
            let rawBytes = [UInt8](data)
            let floats = fp16ToFloat(rawBytes)
            return MLXArray(floats).reshaped(shape)
        default:
            throw ModelError.unsupportedDtype(dtype)
        }
    }
    
    private func bf16ToFloat(_ bytes: [UInt8]) -> [Float] {
        var floats: [Float] = []
        floats.reserveCapacity(bytes.count / 2)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            let bits = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            let floatBits = UInt32(bits) << 16
            floats.append(Float(bitPattern: floatBits))
        }
        return floats
    }
    
    private func fp16ToFloat(_ bytes: [UInt8]) -> [Float] {
        var floats: [Float] = []
        floats.reserveCapacity(bytes.count / 2)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            let bits = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            let sign = (bits >> 15) & 1
            let exponent = (bits >> 10) & 0x1F
            let mantissa = bits & 0x3FF
            
            if exponent == 0 {
                if mantissa == 0 {
                    floats.append(sign == 0 ? 0.0 : -0.0)
                } else {
                    let value = Float(sign == 0 ? 1 : -1) * pow(2, -14) * Float(mantissa) / 1024.0
                    floats.append(value)
                }
            } else if exponent == 31 {
                floats.append(sign == 0 ? Float.infinity : -Float.infinity)
            } else {
                let value = Float(sign == 0 ? 1 : -1) * pow(2, Float(exponent) - 15) * (1 + Float(mantissa) / 1024.0)
                floats.append(value)
            }
        }
        return floats
    }
    
    private func array2DToMLX(_ array: [[Float]]) -> MLXArray {
        guard !array.isEmpty else { return MLXArray([Float]()) }
        let flat = array.flatMap { $0 }
        return MLXArray(flat).reshaped([array.count, array.first?.count ?? 0])
    }
}

struct Qwen3Config: Codable {
    let audioEncoderConfig: AudioEncoderConfig
    let textDecoderConfig: TextDecoderConfig
    let maxGenerationLength: Int
    
    enum CodingKeys: String, CodingKey {
        case audioEncoderConfig = "audio_encoder"
        case textDecoderConfig = "text_decoder"
        case maxGenerationLength = "max_length"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioEncoderConfig = try container.decodeIfPresent(AudioEncoderConfig.self, forKey: .audioEncoderConfig) ?? AudioEncoderConfig()
        textDecoderConfig = try container.decodeIfPresent(TextDecoderConfig.self, forKey: .textDecoderConfig) ?? TextDecoderConfig()
        maxGenerationLength = try container.decodeIfPresent(Int.self, forKey: .maxGenerationLength) ?? 512
    }
}

struct AudioEncoderConfig: Codable {
    let hiddenSize: Int
    let numLayers: Int
    let numHeads: Int
    let intermediateSize: Int
    
    init(hiddenSize: Int = 768, numLayers: Int = 12, numHeads: Int = 12, intermediateSize: Int = 3072) {
        self.hiddenSize = hiddenSize
        self.numLayers = numLayers
        self.numHeads = numHeads
        self.intermediateSize = intermediateSize
    }
}

struct TextDecoderConfig: Codable {
    let hiddenSize: Int
    let numLayers: Int
    let numHeads: Int
    let intermediateSize: Int
    let vocabSize: Int
    
    init(hiddenSize: Int = 896, numLayers: Int = 24, numHeads: Int = 14, intermediateSize: Int = 4864, vocabSize: Int = 151936) {
        self.hiddenSize = hiddenSize
        self.numLayers = numLayers
        self.numHeads = numHeads
        self.intermediateSize = intermediateSize
        self.vocabSize = vocabSize
    }
}

enum ModelError: Error, LocalizedError {
    case weightsNotFound(String)
    case invalidWeightsFormat
    case unsupportedDtype(String)
    
    var errorDescription: String? {
        switch self {
        case .weightsNotFound(let path):
            return "Model weights not found: \(path)"
        case .invalidWeightsFormat:
            return "Invalid model weights format"
        case .unsupportedDtype(let dtype):
            return "Unsupported dtype: \(dtype)"
        }
    }
}
