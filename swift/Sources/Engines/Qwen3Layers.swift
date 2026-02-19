import Foundation
import MLX
import MLXNN

// MARK: - Audio Tower

/// Whisper-style audio encoder for Qwen3-ASR.
/// Processes mel spectrogram through 3 Conv2D layers + 18 transformer encoder layers.
class AudioTower {
    let dModel: Int
    let numHeads: Int
    let ffnDim: Int
    let numLayers: Int

    var conv2d1: AudioConv2D
    var conv2d2: AudioConv2D
    var conv2d3: AudioConv2D
    var convOut: AudioLinear        // [d_model, 7680] — projects flattened conv output
    var encoderLayers: [AudioEncoderLayer]
    var lnPost: AudioLayerNorm
    var proj1: AudioLinear
    var proj2: AudioLinear

    init(dModel: Int, numHeads: Int, ffnDim: Int, numLayers: Int, nMels: Int = 128) {
        self.dModel = dModel
        self.numHeads = numHeads
        self.ffnDim = ffnDim
        self.numLayers = numLayers

        // 3 strided 2D convolutions: mel input [T, nMels] -> [T/8, nMels/8, 480]
        // weight layout: [out_channels, kH, kW, in_channels] (OHWI)
        self.conv2d1 = AudioConv2D(outChannels: 480, kH: 3, kW: 3, inChannels: 1)
        self.conv2d2 = AudioConv2D(outChannels: 480, kH: 3, kW: 3, inChannels: 480)
        self.conv2d3 = AudioConv2D(outChannels: 480, kH: 3, kW: 3, inChannels: 480)
        // After 3 strides of 2 on mel dim: 128/8 = 16; flattened: 16 * 480 = 7680
        let flatDim = (nMels / 8) * 480
        self.convOut = AudioLinear(inDim: flatDim, outDim: dModel, hasBias: false)
        self.encoderLayers = (0..<numLayers).map { _ in
            AudioEncoderLayer(dModel: dModel, numHeads: numHeads, ffnDim: ffnDim)
        }
        self.lnPost = AudioLayerNorm(dim: dModel)
        self.proj1 = AudioLinear(inDim: dModel, outDim: dModel, hasBias: true)
        self.proj2 = AudioLinear(inDim: dModel, outDim: dModel, hasBias: true)  // overridden by weights
    }

    /// Forward pass.
    /// - Parameter mel: [T, nMels] float array
    /// - Returns: [T', outDim] audio features
    func forward(_ mel: MLXArray) -> MLXArray {
        // mel: [T, 128]  ->  [1, T, 128, 1] for Conv2D (NHWC)
        var x = mel.reshaped([1, mel.shape[0], mel.shape[1], 1])

        x = conv2d1.forward(x)          // [1, T/2, 64, 480]
        x = geluApprox(x)
        x = conv2d2.forward(x)          // [1, T/4, 32, 480]
        x = geluApprox(x)
        x = conv2d3.forward(x)          // [1, T/8, 16, 480]
        x = geluApprox(x)

        // Flatten spatial: [1, T/8, 16, 480] -> [T/8, 7680]
        let t8 = x.shape[1]
        x = x.reshaped([t8, x.shape[2] * x.shape[3]])

        // Project to d_model
        x = convOut.forward(x)  // [T/8, dModel]

        // Transformer encoder layers
        for layer in encoderLayers {
            x = layer.forward(x)
        }

        x = lnPost.forward(x)
        x = geluApprox(proj1.forward(x))
        x = proj2.forward(x)

        return x  // [T/8, outDim]
    }

    func loadWeights(_ w: [String: MLXArray]) {
        conv2d1.load(w, prefix: "audio_tower.conv2d1.")
        conv2d2.load(w, prefix: "audio_tower.conv2d2.")
        conv2d3.load(w, prefix: "audio_tower.conv2d3.")
        convOut.loadW(w["audio_tower.conv_out.weight"])
        lnPost.load(w, prefix: "audio_tower.ln_post.")
        proj1.loadFull(w, prefix: "audio_tower.proj1.")
        proj2.loadFull(w, prefix: "audio_tower.proj2.")
        for (i, layer) in encoderLayers.enumerated() {
            layer.load(w, prefix: "audio_tower.layers.\(i).")
        }
    }
}

class AudioEncoderLayer {
    var selfAttnNorm: AudioLayerNorm
    var selfAttn: AudioSelfAttention
    var finalNorm: AudioLayerNorm
    var fc1: AudioLinear
    var fc2: AudioLinear

    init(dModel: Int, numHeads: Int, ffnDim: Int) {
        self.selfAttnNorm = AudioLayerNorm(dim: dModel)
        self.selfAttn = AudioSelfAttention(dModel: dModel, numHeads: numHeads)
        self.finalNorm = AudioLayerNorm(dim: dModel)
        self.fc1 = AudioLinear(inDim: dModel, outDim: ffnDim, hasBias: true)
        self.fc2 = AudioLinear(inDim: ffnDim, outDim: dModel, hasBias: true)
    }

    func forward(_ x: MLXArray) -> MLXArray {
        // Pre-norm self-attention
        var h = x + selfAttn.forward(selfAttnNorm.forward(x))
        // Pre-norm FFN with GELU
        h = h + fc2.forward(geluApprox(fc1.forward(finalNorm.forward(h))))
        return h
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        selfAttnNorm.load(w, prefix: prefix + "self_attn_layer_norm.")
        selfAttn.load(w, prefix: prefix + "self_attn.")
        finalNorm.load(w, prefix: prefix + "final_layer_norm.")
        fc1.loadFull(w, prefix: prefix + "fc1.")
        fc2.loadFull(w, prefix: prefix + "fc2.")
    }
}

class AudioSelfAttention {
    let dModel: Int
    let numHeads: Int
    let headDim: Int
    var qProj: AudioLinear
    var kProj: AudioLinear
    var vProj: AudioLinear
    var outProj: AudioLinear

    init(dModel: Int, numHeads: Int) {
        self.dModel = dModel
        self.numHeads = numHeads
        self.headDim = dModel / numHeads
        self.qProj = AudioLinear(inDim: dModel, outDim: dModel, hasBias: true)
        self.kProj = AudioLinear(inDim: dModel, outDim: dModel, hasBias: true)
        self.vProj = AudioLinear(inDim: dModel, outDim: dModel, hasBias: true)
        self.outProj = AudioLinear(inDim: dModel, outDim: dModel, hasBias: true)
    }

    func forward(_ x: MLXArray) -> MLXArray {
        let T = x.shape[0]
        let scale = Float(1.0 / sqrt(Double(headDim)))

        var q = qProj.forward(x)  // [T, dModel]
        var k = kProj.forward(x)
        var v = vProj.forward(x)

        // Reshape to [T, numHeads, headDim] then [numHeads, T, headDim]
        q = q.reshaped([T, numHeads, headDim]).transposed(0, 1).reshaped([1, numHeads, T, headDim])
        k = k.reshaped([T, numHeads, headDim]).transposed(0, 1).reshaped([1, numHeads, T, headDim])
        v = v.reshaped([T, numHeads, headDim]).transposed(0, 1).reshaped([1, numHeads, T, headDim])

        var scores = MLX.matmul(q, k.transposed(-2, -1)) * MLXArray(scale)
        scores = softmaxFn(scores, axis: -1)
        var out = MLX.matmul(scores, v)  // [1, numHeads, T, headDim]
        out = out.reshaped([T, dModel])

        return outProj.forward(out)
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        qProj.loadFull(w, prefix: prefix + "q_proj.")
        kProj.loadFull(w, prefix: prefix + "k_proj.")
        vProj.loadFull(w, prefix: prefix + "v_proj.")
        outProj.loadFull(w, prefix: prefix + "out_proj.")
    }
}

// MARK: - Text Decoder (Qwen3 GQA Decoder-Only LM)

/// Qwen3 decoder-only LM with grouped-query attention and affine-quantized weights.
class TextDecoder {
    let hiddenSize: Int
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let numLayers: Int
    let vocabSize: Int
    let ropeTheta: Float

    var embedTokens: QuantizedLinear   // embedding table (quantized)
    var layers: [Qwen3Layer]
    var norm: RMSNorm

    init(hiddenSize: Int, numHeads: Int, numKVHeads: Int, headDim: Int,
         numLayers: Int, vocabSize: Int, ropeTheta: Float) {
        self.hiddenSize = hiddenSize
        self.numHeads = numHeads
        self.numKVHeads = numKVHeads
        self.headDim = headDim
        self.numLayers = numLayers
        self.vocabSize = vocabSize
        self.ropeTheta = ropeTheta

        self.embedTokens = QuantizedLinear(outDim: vocabSize, inDimPacked: hiddenSize / 8,
                                           groupSize: 64, bits: 4)
        self.layers = (0..<numLayers).map { _ in
            Qwen3Layer(hiddenSize: hiddenSize, numHeads: numHeads, numKVHeads: numKVHeads,
                       headDim: headDim, ropeTheta: ropeTheta)
        }
        self.norm = RMSNorm(dim: hiddenSize)
    }

    /// Embed token IDs.
    func embed(_ ids: [Int32]) -> MLXArray {
        // ids: [N] -> embeddings: [N, hiddenSize]
        let idArray = MLXArray(ids)
        // Dequantize embedding rows
        return embedTokens.embed(idArray)
    }

    /// Run one forward step returning logits over vocab.
    /// - Parameters:
    ///   - hidden: [S, hiddenSize] (sequence of token embeddings, possibly with injected audio)
    ///   - kvCaches: per-layer KV caches for incremental decoding
    ///   - offset: current position offset for RoPE
    func forward(_ hidden: MLXArray, kvCaches: [GQAKVCache], offset: Int) -> MLXArray {
        var x = hidden
        for (layer, cache) in zip(layers, kvCaches) {
            x = layer.forward(x, kvCache: cache, offset: offset)
        }
        x = norm.forward(x)
        // LM head — reuse embed_tokens weight (tied embeddings)
        // logits: [S, vocabSize]
        return embedTokens.linearForward(x)
    }

    func loadWeights(_ w: [String: MLXArray]) {
        embedTokens.load(w, prefix: "model.embed_tokens.")
        norm.load(w, prefix: "model.norm.")
        for (i, layer) in layers.enumerated() {
            layer.load(w, prefix: "model.layers.\(i).")
        }
    }
}

class Qwen3Layer {
    let hiddenSize: Int
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int

    var inputNorm: RMSNorm
    var selfAttn: Qwen3Attention
    var postNorm: RMSNorm
    var mlp: Qwen3MLP

    init(hiddenSize: Int, numHeads: Int, numKVHeads: Int, headDim: Int, ropeTheta: Float) {
        self.hiddenSize = hiddenSize
        self.numHeads = numHeads
        self.numKVHeads = numKVHeads
        self.headDim = headDim
        self.inputNorm = RMSNorm(dim: hiddenSize)
        self.selfAttn = Qwen3Attention(hiddenSize: hiddenSize, numHeads: numHeads,
                                        numKVHeads: numKVHeads, headDim: headDim,
                                        ropeTheta: ropeTheta)
        self.postNorm = RMSNorm(dim: hiddenSize)
        self.mlp = Qwen3MLP(hiddenSize: hiddenSize, intermediateSize: hiddenSize * 3)
    }

    func forward(_ x: MLXArray, kvCache: GQAKVCache, offset: Int) -> MLXArray {
        var h = x + selfAttn.forward(inputNorm.forward(x), kvCache: kvCache, offset: offset)
        h = h + mlp.forward(postNorm.forward(h))
        return h
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        inputNorm.load(w, prefix: prefix + "input_layernorm.")
        selfAttn.load(w, prefix: prefix + "self_attn.")
        postNorm.load(w, prefix: prefix + "post_attention_layernorm.")
        mlp.load(w, prefix: prefix + "mlp.")
    }
}

class Qwen3Attention {
    let hiddenSize: Int
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let ropeTheta: Float
    let kvRepeats: Int

    var qProj: QuantizedLinear
    var kProj: QuantizedLinear
    var vProj: QuantizedLinear
    var oProj: QuantizedLinear
    var qNorm: RMSNorm
    var kNorm: RMSNorm

    init(hiddenSize: Int, numHeads: Int, numKVHeads: Int, headDim: Int, ropeTheta: Float) {
        self.hiddenSize = hiddenSize
        self.numHeads = numHeads
        self.numKVHeads = numKVHeads
        self.headDim = headDim
        self.ropeTheta = ropeTheta
        self.kvRepeats = numHeads / numKVHeads

        let qOutDim = numHeads * headDim
        let kvOutDim = numKVHeads * headDim
        let inPackedDim = hiddenSize / 8
        self.qProj = QuantizedLinear(outDim: qOutDim, inDimPacked: inPackedDim, groupSize: 64, bits: 4)
        self.kProj = QuantizedLinear(outDim: kvOutDim, inDimPacked: inPackedDim, groupSize: 64, bits: 4)
        self.vProj = QuantizedLinear(outDim: kvOutDim, inDimPacked: inPackedDim, groupSize: 64, bits: 4)
        // o_proj: [hiddenSize, qOutDim] but stored transposed
        let oInPacked = qOutDim / 8
        self.oProj = QuantizedLinear(outDim: hiddenSize, inDimPacked: oInPacked, groupSize: 64, bits: 4)
        self.qNorm = RMSNorm(dim: headDim)
        self.kNorm = RMSNorm(dim: headDim)
    }

    func forward(_ x: MLXArray, kvCache: GQAKVCache, offset: Int) -> MLXArray {
        let S = x.shape[0]
        let scale = Float(1.0 / sqrt(Double(headDim)))

        var q = qProj.forward(x)  // [S, numHeads*headDim]
        var k = kProj.forward(x)  // [S, numKVHeads*headDim]
        var v = vProj.forward(x)  // [S, numKVHeads*headDim]

        // Reshape for per-head norms
        q = q.reshaped([S, numHeads, headDim])
        k = k.reshaped([S, numKVHeads, headDim])
        v = v.reshaped([S, numKVHeads, headDim])

        // Apply per-head RMSNorm
        q = qNorm.forwardHeads(q)  // [S, numHeads, headDim]
        k = kNorm.forwardHeads(k)  // [S, numKVHeads, headDim]

        // Apply RoPE
        q = applyRope(q, offset: offset, theta: ropeTheta)
        k = applyRope(k, offset: offset, theta: ropeTheta)

        // Update KV cache and get full sequences
        let (fullK, fullV) = kvCache.update(k: k, v: v)
        let fullLen = fullK.shape[0]

        // Expand KV for GQA: [fullLen, numKVHeads, headDim] -> [fullLen, numHeads, headDim]
        let fullKExp = expandKV(fullK, repeats: kvRepeats)  // [fullLen, numHeads, headDim]
        let fullVExp = expandKV(fullV, repeats: kvRepeats)

        // [numHeads, S, headDim] x [numHeads, headDim, fullLen] -> [numHeads, S, fullLen]
        let qT = q.transposed(1, 0, 2)           // [numHeads, S, headDim]
        let kT = fullKExp.transposed(1, 2, 0)    // [numHeads, headDim, fullLen]
        let vT = fullVExp.transposed(1, 0, 2)    // [numHeads, fullLen, headDim]

        var scores = MLX.matmul(qT, kT) * MLXArray(scale)  // [numHeads, S, fullLen]

        // Causal mask: query position offset..<offset+S should only see positions <= position
        if S > 1 {
            scores = applyCausalMask(scores, offset: offset, queryLen: S, keyLen: fullLen)
        }

        scores = softmaxFn(scores, axis: -1)
        var out = MLX.matmul(scores, vT)  // [numHeads, S, headDim]
        out = out.transposed(1, 0, 2).reshaped([S, numHeads * headDim])  // [S, numHeads*headDim]

        return oProj.forward(out)  // [S, hiddenSize]
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        qProj.load(w, prefix: prefix + "q_proj.")
        kProj.load(w, prefix: prefix + "k_proj.")
        vProj.load(w, prefix: prefix + "v_proj.")
        oProj.load(w, prefix: prefix + "o_proj.")
        qNorm.load(w, prefix: prefix + "q_norm.")
        kNorm.load(w, prefix: prefix + "k_norm.")
    }
}

class Qwen3MLP {
    var gateProj: QuantizedLinear
    var upProj: QuantizedLinear
    var downProj: QuantizedLinear

    init(hiddenSize: Int, intermediateSize: Int) {
        let inPacked = hiddenSize / 8
        let downInPacked = intermediateSize / 8
        self.gateProj = QuantizedLinear(outDim: intermediateSize, inDimPacked: inPacked, groupSize: 64, bits: 4)
        self.upProj = QuantizedLinear(outDim: intermediateSize, inDimPacked: inPacked, groupSize: 64, bits: 4)
        self.downProj = QuantizedLinear(outDim: hiddenSize, inDimPacked: downInPacked, groupSize: 64, bits: 4)
    }

    func forward(_ x: MLXArray) -> MLXArray {
        let gate = siluFn(gateProj.forward(x))
        let up = upProj.forward(x)
        return downProj.forward(gate * up)
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        gateProj.load(w, prefix: prefix + "gate_proj.")
        upProj.load(w, prefix: prefix + "up_proj.")
        downProj.load(w, prefix: prefix + "down_proj.")
    }
}

// MARK: - Primitives

/// Affine-quantized linear layer (4-bit or 8-bit, group_size=64).
/// Weights stored as packed U32 nibbles.
class QuantizedLinear {
    let outDim: Int
    let inDimPacked: Int   // = inDim / 8 for 4-bit
    let groupSize: Int
    let bits: Int

    var weight: MLXArray   // [outDim, inDimPacked] U32
    var scales: MLXArray   // [outDim, inDim/groupSize] BF16
    var biases: MLXArray   // [outDim, inDim/groupSize] BF16

    init(outDim: Int, inDimPacked: Int, groupSize: Int, bits: Int) {
        self.outDim = outDim
        self.inDimPacked = inDimPacked
        self.groupSize = groupSize
        self.bits = bits
        let inDim = inDimPacked * 8
        let numGroups = inDim / groupSize
        self.weight = MLX.zeros([outDim, inDimPacked], type: UInt32.self)
        self.scales = MLX.ones([outDim, numGroups], type: Float.self)
        self.biases = MLX.zeros([outDim, numGroups], type: Float.self)
    }

    /// Dequantize and compute x @ W^T.
    func forward(_ x: MLXArray) -> MLXArray {
        let W = dequantize()  // [outDim, inDim]
        // x: [S, inDim], W: [outDim, inDim] -> x @ W^T = [S, outDim]
        return MLX.matmul(x, W.transposed(-2, -1))
    }

    /// Embed lookup: index rows of dequantized weight table.
    func embed(_ ids: MLXArray) -> MLXArray {
        let W = dequantize()  // [vocabSize, hiddenSize]
        return W[ids]
    }

    /// Use dequantized weight as LM head (tied embeddings).
    func linearForward(_ x: MLXArray) -> MLXArray {
        let W = dequantize()  // [vocabSize, hiddenSize]
        // x: [S, hiddenSize] -> [S, vocabSize]
        return MLX.matmul(x, W.transposed(-2, -1))
    }

    func dequantize() -> MLXArray {
        // Unpack 4-bit nibbles from U32
        // weight: [outDim, inDimPacked]  (each U32 has 8 nibbles)
        let inDim = inDimPacked * 8
        let numGroups = inDim / groupSize

        // Convert U32 to int array and unpack nibbles
        let w32 = weight.asArray(UInt32.self)
        var unpacked = [Float](repeating: 0, count: outDim * inDim)

        for row in 0..<outDim {
            let scaleRow = scales.asArray(Float.self)
            let biasRow = biases.asArray(Float.self)
            for col in 0..<inDimPacked {
                let packed = w32[row * inDimPacked + col]
                for nibble in 0..<8 {
                    let q = Int((packed >> (nibble * 4)) & 0xF)
                    let outCol = col * 8 + nibble
                    let group = outCol / groupSize
                    let s = scaleRow[row * numGroups + group]
                    let b = biasRow[row * numGroups + group]
                    // affine dequant: val = q * scale + bias
                    unpacked[row * inDim + outCol] = Float(q) * s + b
                }
            }
        }
        return MLXArray(unpacked).reshaped([outDim, inDim])
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        if let wt = w[prefix + "weight"] { weight = wt }
        if let sc = w[prefix + "scales"] { scales = sc }
        if let bi = w[prefix + "biases"] { biases = bi }
    }

    func loadW(_ wt: MLXArray?) {
        if let wt { weight = wt }
    }
}

class AudioLinear {
    let inDim: Int
    let outDim: Int
    let hasBias: Bool
    var weight: MLXArray   // [outDim, inDim] BF16
    var bias: MLXArray?

    init(inDim: Int, outDim: Int, hasBias: Bool) {
        self.inDim = inDim
        self.outDim = outDim
        self.hasBias = hasBias
        self.weight = MLX.zeros([outDim, inDim], type: Float.self)
        if hasBias {
            self.bias = MLX.zeros([outDim], type: Float.self)
        }
    }

    func forward(_ x: MLXArray) -> MLXArray {
        var out = MLX.matmul(x, weight.transposed(-2, -1))
        if let b = bias { out = out + b }
        return out
    }

    func loadW(_ wt: MLXArray?) {
        if let wt { weight = wt }
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        if let wt = w[prefix + "weight"] { weight = wt }
        if let b = w[prefix + "bias"] { bias = b }
    }

    func loadFull(_ w: [String: MLXArray], prefix: String) {
        load(w, prefix: prefix)
    }
}

class AudioConv2D {
    let outChannels: Int
    let kH: Int
    let kW: Int
    let inChannels: Int
    // weight: [outChannels, kH, kW, inChannels] (OHWI for MLX conv2d)
    var weight: MLXArray
    var bias: MLXArray

    init(outChannels: Int, kH: Int, kW: Int, inChannels: Int) {
        self.outChannels = outChannels
        self.kH = kH
        self.kW = kW
        self.inChannels = inChannels
        self.weight = MLX.zeros([outChannels, kH, kW, inChannels], type: Float.self)
        self.bias = MLX.zeros([outChannels], type: Float.self)
    }

    /// x: [batch, H, W, inChannels] -> [batch, H/2, W/2, outChannels]
    func forward(_ x: MLXArray) -> MLXArray {
        // MLX conv2d expects filters in [outC, kH, kW, inC] format
        // and input in [batch, H, W, inC] — NHWC
        var out = MLX.conv2d(x, weight,
                             stride: [2, 2],
                             padding: [1, 1],
                             dilation: [1, 1],
                             groups: 1)
        out = out + bias
        return out
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        if let wt = w[prefix + "weight"] { weight = wt }
        if let b = w[prefix + "bias"] { bias = b }
    }
}

class AudioLayerNorm {
    var weight: MLXArray
    var bias: MLXArray
    let eps: Float

    init(dim: Int, eps: Float = 1e-5) {
        self.weight = MLX.ones([dim], type: Float.self)
        self.bias = MLX.zeros([dim], type: Float.self)
        self.eps = eps
    }

    func forward(_ x: MLXArray) -> MLXArray {
        let mean = MLX.mean(x, axis: -1, keepDims: true)
        let variance = MLX.mean((x - mean) * (x - mean), axis: -1, keepDims: true)
        let normalized = (x - mean) / MLX.sqrt(variance + MLXArray(eps))
        return normalized * weight + bias
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        if let wt = w[prefix + "weight"] { weight = wt }
        if let b = w[prefix + "bias"] { bias = b }
    }
}

class RMSNorm {
    var weight: MLXArray
    let eps: Float

    init(dim: Int, eps: Float = 1e-6) {
        self.weight = MLX.ones([dim], type: Float.self)
        self.eps = eps
    }

    func forward(_ x: MLXArray) -> MLXArray {
        let ms = MLX.mean(x * x, axis: -1, keepDims: true)
        let rms = MLX.rsqrt(ms + MLXArray(eps))
        return x * rms * weight
    }

    /// Apply RMSNorm independently to each head: x [S, numHeads, headDim]
    func forwardHeads(_ x: MLXArray) -> MLXArray {
        let ms = MLX.mean(x * x, axis: -1, keepDims: true)
        let rms = MLX.rsqrt(ms + MLXArray(eps))
        return x * rms * weight
    }

    func load(_ w: [String: MLXArray], prefix: String) {
        if let wt = w[prefix + "weight"] { weight = wt }
    }
}

/// KV cache for GQA decoder.
class GQAKVCache {
    var k: MLXArray?  // [seqLen, numKVHeads, headDim]
    var v: MLXArray?

    func update(k newK: MLXArray, v newV: MLXArray) -> (MLXArray, MLXArray) {
        if let existingK = k, let existingV = v {
            k = MLX.concatenated([existingK, newK], axis: 0)
            v = MLX.concatenated([existingV, newV], axis: 0)
        } else {
            k = newK
            v = newV
        }
        return (k!, v!)
    }

    func reset() {
        k = nil
        v = nil
    }
}

// MARK: - Math utilities

func geluApprox(_ x: MLXArray) -> MLXArray {
    let c = MLXArray(Float(sqrt(2.0 / Double.pi)))
    return 0.5 * x * (1.0 + MLX.tanh(c * (x + 0.044715 * x * x * x)))
}

func siluFn(_ x: MLXArray) -> MLXArray {
    return x * MLX.sigmoid(x)
}

func softmaxFn(_ x: MLXArray, axis: Int) -> MLXArray {
    let maxVal = MLX.max(x, axis: axis, keepDims: true)
    let expX = MLX.exp(x - maxVal)
    return expX / MLX.sum(expX, axis: axis, keepDims: true)
}

/// Rotary Position Embedding (RoPE). Applied to [S, numHeads, headDim].
func applyRope(_ x: MLXArray, offset: Int, theta: Float) -> MLXArray {
    let S = x.shape[0]
    let _ = x.shape[1]  // numHeads (unused — RoPE is applied per element)
    let headDim = x.shape[2]
    let half = headDim / 2

    var cosVals = [Float](repeating: 0, count: S * half)
    var sinVals = [Float](repeating: 0, count: S * half)

    for pos in 0..<S {
        for i in 0..<half {
            let freq = 1.0 / pow(theta, Float(2 * i) / Float(headDim))
            let angle = Float(pos + offset) * freq
            cosVals[pos * half + i] = cos(angle)
            sinVals[pos * half + i] = sin(angle)
        }
    }

    let cosArr = MLXArray(cosVals).reshaped([S, 1, half])  // broadcast over heads
    let sinArr = MLXArray(sinVals).reshaped([S, 1, half])

    // Split x into two halves along last dim
    let x1 = x[0..., 0..., 0..<half]
    let x2 = x[0..., 0..., half...]

    let rotX1 = x1 * cosArr - x2 * sinArr
    let rotX2 = x2 * cosArr + x1 * sinArr

    return MLX.concatenated([rotX1, rotX2], axis: -1)
}

/// Expand KV heads for GQA: [S, numKVHeads, headDim] -> [S, numHeads, headDim]
func expandKV(_ x: MLXArray, repeats: Int) -> MLXArray {
    if repeats == 1 { return x }
    let S = x.shape[0]
    let numKVHeads = x.shape[1]
    let headDim = x.shape[2]
    // [S, numKVHeads, headDim] -> [S, numKVHeads, 1, headDim] -> [S, numKVHeads, repeats, headDim] -> [S, numHeads, headDim]
    let expanded = MLX.tiled(x.reshaped([S, numKVHeads, 1, headDim]), repetitions: [1, 1, repeats, 1])
    return expanded.reshaped([S, numKVHeads * repeats, headDim])
}

/// Apply causal mask to attention scores [numHeads, queryLen, keyLen].
func applyCausalMask(_ scores: MLXArray, offset: Int, queryLen: Int, keyLen: Int) -> MLXArray {
    // Build causal mask: query at position (offset+q) can see key at position k if k <= offset+q
    var mask = [Float](repeating: 0, count: queryLen * keyLen)
    for q in 0..<queryLen {
        let queryPos = offset + q
        for k in 0..<keyLen {
            mask[q * keyLen + k] = k <= queryPos ? 0 : -Float.infinity
        }
    }
    let maskArr = MLXArray(mask).reshaped([1, queryLen, keyLen])
    return scores + maskArr
}
