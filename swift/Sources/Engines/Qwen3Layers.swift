import Foundation
import MLX
import MLXNN

class AudioEncoder {
    let config: AudioEncoderConfig
    var convStem: ConvStem
    var transformerLayers: [TransformerEncoderLayer]
    var layerNorm: LayerNorm
    
    init(config: AudioEncoderConfig) {
        self.config = config
        
        self.convStem = ConvStem(
            inputChannels: 128,
            hiddenSize: config.hiddenSize
        )
        
        self.transformerLayers = (0..<config.numLayers).map { _ in
            TransformerEncoderLayer(
                hiddenSize: config.hiddenSize,
                numHeads: config.numHeads,
                intermediateSize: config.intermediateSize
            )
        }
        
        self.layerNorm = LayerNorm(dimensions: config.hiddenSize)
    }
    
    func forward(_ x: MLXArray) -> MLXArray {
        var hidden = convStem.forward(x)
        
        for layer in transformerLayers {
            hidden = layer.forward(hidden)
        }
        
        return layerNorm.forward(hidden)
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        convStem.loadWeights(weights, prefix: prefix + "conv_stem.")
        for (i, layer) in transformerLayers.enumerated() {
            layer.loadWeights(weights, prefix: prefix + "layers.\(i).")
        }
        layerNorm.loadWeights(weights, prefix: prefix + "layer_norm.")
    }
}

class ConvStem {
    var conv1: Conv2d
    var conv2: Conv2d
    var norm1: LayerNorm
    var norm2: LayerNorm
    
    init(inputChannels: Int, hiddenSize: Int) {
        self.conv1 = Conv2d(inputChannels: inputChannels, outputChannels: hiddenSize, kernelSize: 3, stride: 2, padding: 1)
        self.conv2 = Conv2d(inputChannels: hiddenSize, outputChannels: hiddenSize, kernelSize: 3, stride: 2, padding: 1)
        self.norm1 = LayerNorm(dimensions: hiddenSize)
        self.norm2 = LayerNorm(dimensions: hiddenSize)
    }
    
    func forward(_ x: MLXArray) -> MLXArray {
        var hidden = conv1.forward(x)
        hidden = gelu(hidden)
        hidden = norm1.forward(hidden)
        
        hidden = conv2.forward(hidden)
        hidden = gelu(hidden)
        hidden = norm2.forward(hidden)
        
        return hidden
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        conv1.weight = weights[prefix + "conv1.weight"] ?? conv1.weight
        conv1.bias = weights[prefix + "conv1.bias"] ?? conv1.bias
        conv2.weight = weights[prefix + "conv2.weight"] ?? conv2.weight
        conv2.bias = weights[prefix + "conv2.bias"] ?? conv2.bias
        norm1.weight = weights[prefix + "norm1.weight"] ?? norm1.weight
        norm1.bias = weights[prefix + "norm1.bias"] ?? norm1.bias
        norm2.weight = weights[prefix + "norm2.weight"] ?? norm2.weight
        norm2.bias = weights[prefix + "norm2.bias"] ?? norm2.bias
    }
}

class TransformerEncoderLayer {
    let hiddenSize: Int
    let numHeads: Int
    var selfAttn: MultiHeadAttention
    var mlp: MLP
    var norm1: LayerNorm
    var norm2: LayerNorm
    
    init(hiddenSize: Int, numHeads: Int, intermediateSize: Int) {
        self.hiddenSize = hiddenSize
        self.numHeads = numHeads
        
        self.selfAttn = MultiHeadAttention(hiddenSize: hiddenSize, numHeads: numHeads)
        self.mlp = MLP(hiddenSize: hiddenSize, intermediateSize: intermediateSize)
        self.norm1 = LayerNorm(dimensions: hiddenSize)
        self.norm2 = LayerNorm(dimensions: hiddenSize)
    }
    
    func forward(_ x: MLXArray) -> MLXArray {
        var hidden = x + selfAttn.forward(norm1.forward(x))
        hidden = hidden + mlp.forward(norm2.forward(hidden))
        return hidden
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        selfAttn.loadWeights(weights, prefix: prefix + "self_attn.")
        mlp.loadWeights(weights, prefix: prefix + "mlp.")
        norm1.weight = weights[prefix + "norm1.weight"] ?? norm1.weight
        norm1.bias = weights[prefix + "norm1.bias"] ?? norm1.bias
        norm2.weight = weights[prefix + "norm2.weight"] ?? norm2.weight
        norm2.bias = weights[prefix + "norm2.bias"] ?? norm2.bias
    }
}

class TextDecoder {
    let config: TextDecoderConfig
    var embedding: Embedding
    var transformerLayers: [TransformerDecoderLayer]
    var norm: LayerNorm
    var lmHead: Linear
    
    init(config: TextDecoderConfig) {
        self.config = config
        
        self.embedding = Embedding(vocabSize: config.vocabSize, dimensions: config.hiddenSize)
        self.transformerLayers = (0..<config.numLayers).map { _ in
            TransformerDecoderLayer(
                hiddenSize: config.hiddenSize,
                numHeads: config.numHeads,
                intermediateSize: config.intermediateSize
            )
        }
        self.norm = LayerNorm(dimensions: config.hiddenSize)
        self.lmHead = Linear(inputDimensions: config.hiddenSize, outputDimensions: config.vocabSize)
    }
    
    func forward(_ inputIds: MLXArray, encoderHidden: MLXArray) -> (MLXArray, MLXArray) {
        var hidden = embedding.forward(inputIds)
        
        for layer in transformerLayers {
            hidden = layer.forward(hidden, encoderHidden: encoderHidden)
        }
        
        hidden = norm.forward(hidden)
        let logits = lmHead.forward(hidden)
        
        return (logits, hidden)
    }
    
    func forwardIncremental(_ inputIds: MLXArray, encoderHidden: MLXArray, kvCache: KVCache, step: Int) -> MLXArray {
        var hidden = embedding.forward(inputIds)
        
        for (i, layer) in transformerLayers.enumerated() {
            hidden = layer.forwardIncremental(hidden, encoderHidden: encoderHidden, kvCache: kvCache, layerIdx: i)
        }
        
        hidden = norm.forward(hidden)
        let logits = lmHead.forward(hidden)
        
        return logits
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        embedding.weight = weights[prefix + "embed_tokens.weight"] ?? embedding.weight
        for (i, layer) in transformerLayers.enumerated() {
            layer.loadWeights(weights, prefix: prefix + "layers.\(i).")
        }
        norm.weight = weights[prefix + "norm.weight"] ?? norm.weight
        norm.bias = weights[prefix + "norm.bias"] ?? norm.bias
        lmHead.weight = weights[prefix + "lm_head.weight"] ?? lmHead.weight
    }
}

class TransformerDecoderLayer {
    var selfAttn: MultiHeadAttention
    var crossAttn: MultiHeadAttention
    var mlp: MLP
    var norm1: LayerNorm
    var norm2: LayerNorm
    var norm3: LayerNorm
    
    init(hiddenSize: Int, numHeads: Int, intermediateSize: Int) {
        self.selfAttn = MultiHeadAttention(hiddenSize: hiddenSize, numHeads: numHeads)
        self.crossAttn = MultiHeadAttention(hiddenSize: hiddenSize, numHeads: numHeads)
        self.mlp = MLP(hiddenSize: hiddenSize, intermediateSize: intermediateSize)
        self.norm1 = LayerNorm(dimensions: hiddenSize)
        self.norm2 = LayerNorm(dimensions: hiddenSize)
        self.norm3 = LayerNorm(dimensions: hiddenSize)
    }
    
    func forward(_ x: MLXArray, encoderHidden: MLXArray) -> MLXArray {
        var hidden = x + selfAttn.forward(norm1.forward(x))
        hidden = hidden + crossAttn.forward(norm2.forward(hidden), encoderHidden: encoderHidden)
        hidden = hidden + mlp.forward(norm3.forward(hidden))
        return hidden
    }
    
    func forwardIncremental(_ x: MLXArray, encoderHidden: MLXArray, kvCache: KVCache, layerIdx: Int) -> MLXArray {
        let attnOut = selfAttn.forwardWithCache(norm1.forward(x), kvCache: kvCache, layerIdx: layerIdx)
        var hidden = x + attnOut
        hidden = hidden + crossAttn.forward(norm2.forward(hidden), encoderHidden: encoderHidden)
        hidden = hidden + mlp.forward(norm3.forward(hidden))
        return hidden
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        selfAttn.loadWeights(weights, prefix: prefix + "self_attn.")
        crossAttn.loadWeights(weights, prefix: prefix + "cross_attn.")
        mlp.loadWeights(weights, prefix: prefix + "mlp.")
        norm1.weight = weights[prefix + "norm1.weight"] ?? norm1.weight
        norm1.bias = weights[prefix + "norm1.bias"] ?? norm1.bias
        norm2.weight = weights[prefix + "norm2.weight"] ?? norm2.weight
        norm2.bias = weights[prefix + "norm2.bias"] ?? norm2.bias
        norm3.weight = weights[prefix + "norm3.weight"] ?? norm3.weight
        norm3.bias = weights[prefix + "norm3.bias"] ?? norm3.bias
    }
}

class Projector {
    var linear1: Linear
    var linear2: Linear
    
    init(inputDim: Int, outputDim: Int) {
        let intermediateDim = max(inputDim, outputDim)
        self.linear1 = Linear(inputDimensions: inputDim, outputDimensions: intermediateDim)
        self.linear2 = Linear(inputDimensions: intermediateDim, outputDimensions: outputDim)
    }
    
    func forward(_ x: MLXArray) -> MLXArray {
        var hidden = linear1.forward(x)
        hidden = gelu(hidden)
        hidden = linear2.forward(hidden)
        return hidden
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        linear1.weight = weights[prefix + "linear1.weight"] ?? linear1.weight
        linear1.bias = weights[prefix + "linear1.bias"] ?? linear1.bias
        linear2.weight = weights[prefix + "linear2.weight"] ?? linear2.weight
        linear2.bias = weights[prefix + "linear2.bias"] ?? linear2.bias
    }
}

class MultiHeadAttention {
    let hiddenSize: Int
    let numHeads: Int
    let headDim: Int
    var qProj: Linear
    var kProj: Linear
    var vProj: Linear
    var oProj: Linear
    
    init(hiddenSize: Int, numHeads: Int) {
        self.hiddenSize = hiddenSize
        self.numHeads = numHeads
        self.headDim = hiddenSize / numHeads
        
        self.qProj = Linear(inputDimensions: hiddenSize, outputDimensions: hiddenSize)
        self.kProj = Linear(inputDimensions: hiddenSize, outputDimensions: hiddenSize)
        self.vProj = Linear(inputDimensions: hiddenSize, outputDimensions: hiddenSize)
        self.oProj = Linear(inputDimensions: hiddenSize, outputDimensions: hiddenSize)
    }
    
    func forward(_ x: MLXArray, encoderHidden: MLXArray? = nil) -> MLXArray {
        let batchSize = x.shape[0]
        let seqLen = x.shape[1]
        
        let kvInput = encoderHidden ?? x
        
        var q = qProj.forward(x)
        var k = kProj.forward(kvInput)
        var v = vProj.forward(kvInput)
        
        q = q.reshaped([batchSize, seqLen, numHeads, headDim]).transposed(1, 2)
        k = k.reshaped([kvInput.shape[0], kvInput.shape[1], numHeads, headDim]).transposed(1, 2)
        v = v.reshaped([kvInput.shape[0], kvInput.shape[1], numHeads, headDim]).transposed(1, 2)
        
        let scale = 1.0 / sqrt(Float(headDim))
        var scores = MLX.matmul(q, k.transposed(-2, -1)) * MLXArray(scale)
        
        scores = softmax(scores, axis: -1)
        
        var output = MLX.matmul(scores, v)
        output = output.transposed(1, 2).reshaped([batchSize, seqLen, hiddenSize])
        
        return oProj.forward(output)
    }
    
    func forwardWithCache(_ x: MLXArray, kvCache: KVCache, layerIdx: Int) -> MLXArray {
        let batchSize = x.shape[0]
        let seqLen = x.shape[1]
        
        var q = qProj.forward(x)
        var k = kProj.forward(x)
        var v = vProj.forward(x)
        
        q = q.reshaped([batchSize, seqLen, numHeads, headDim]).transposed(1, 2)
        k = k.reshaped([batchSize, seqLen, numHeads, headDim]).transposed(1, 2)
        v = v.reshaped([batchSize, seqLen, numHeads, headDim]).transposed(1, 2)
        
        // Update KV cache and get full K, V
        let (cachedK, cachedV) = kvCache.update(k: k, v: v, layer: layerIdx)
        
        let scale = 1.0 / sqrt(Float(headDim))
        var scores = MLX.matmul(q, cachedK.transposed(-2, -1)) * MLXArray(scale)
        
        scores = softmax(scores, axis: -1)
        
        var output = MLX.matmul(scores, cachedV)
        output = output.transposed(1, 2).reshaped([batchSize, seqLen, hiddenSize])
        
        return oProj.forward(output)
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        qProj.weight = weights[prefix + "q_proj.weight"] ?? qProj.weight
        qProj.bias = weights[prefix + "q_proj.bias"] ?? qProj.bias
        kProj.weight = weights[prefix + "k_proj.weight"] ?? kProj.weight
        kProj.bias = weights[prefix + "k_proj.bias"] ?? kProj.bias
        vProj.weight = weights[prefix + "v_proj.weight"] ?? vProj.weight
        vProj.bias = weights[prefix + "v_proj.bias"] ?? vProj.bias
        oProj.weight = weights[prefix + "o_proj.weight"] ?? oProj.weight
        oProj.bias = weights[prefix + "o_proj.bias"] ?? oProj.bias
    }
}

class MLP {
    var gateProj: Linear
    var upProj: Linear
    var downProj: Linear
    
    init(hiddenSize: Int, intermediateSize: Int) {
        self.gateProj = Linear(inputDimensions: hiddenSize, outputDimensions: intermediateSize)
        self.upProj = Linear(inputDimensions: hiddenSize, outputDimensions: intermediateSize)
        self.downProj = Linear(inputDimensions: intermediateSize, outputDimensions: hiddenSize)
    }
    
    func forward(_ x: MLXArray) -> MLXArray {
        let gate = silu(gateProj.forward(x))
        let up = upProj.forward(x)
        return downProj.forward(gate * up)
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        gateProj.weight = weights[prefix + "gate_proj.weight"] ?? gateProj.weight
        upProj.weight = weights[prefix + "up_proj.weight"] ?? upProj.weight
        downProj.weight = weights[prefix + "down_proj.weight"] ?? downProj.weight
    }
}

class LayerNorm {
    var weight: MLXArray
    var bias: MLXArray
    let eps: Float
    
    init(dimensions: Int, eps: Float = 1e-5) {
        self.weight = MLXArray([Float](repeating: 1.0, count: dimensions))
        self.bias = MLXArray([Float](repeating: 0.0, count: dimensions))
        self.eps = eps
    }
    
    func forward(_ x: MLXArray) -> MLXArray {
        let mean = MLX.mean(x, axis: -1, keepDims: true)
        let variance = MLX.variance(x, axis: -1, keepDims: true)
        let normalized = (x - mean) / MLX.sqrt(variance + MLXArray(eps))
        return normalized * weight + bias
    }
    
    func loadWeights(_ weights: [String: MLXArray], prefix: String) {
        if let w = weights[prefix + "weight"] {
            weight = w
        }
        if let b = weights[prefix + "bias"] {
            bias = b
        }
    }
}

class Embedding {
    var weight: MLXArray
    let vocabSize: Int
    let dimensions: Int
    
    init(vocabSize: Int, dimensions: Int) {
        self.vocabSize = vocabSize
        self.dimensions = dimensions
        self.weight = MLXArray([Float](repeating: 0, count: vocabSize * dimensions)).reshaped([vocabSize, dimensions])
    }
    
    func forward(_ ids: MLXArray) -> MLXArray {
        return weight[ids]
    }
}

class Linear {
    var weight: MLXArray
    var bias: MLXArray?
    let inputDimensions: Int
    let outputDimensions: Int
    
    init(inputDimensions: Int, outputDimensions: Int, hasBias: Bool = true) {
        self.inputDimensions = inputDimensions
        self.outputDimensions = outputDimensions
        
        let scale = sqrt(1.0 / Float(inputDimensions))
        let wData = (0..<outputDimensions * inputDimensions).map { _ in Float.random(in: -scale...scale) }
        self.weight = MLXArray(wData).reshaped([outputDimensions, inputDimensions])
        
        if hasBias {
            self.bias = MLXArray([Float](repeating: 0, count: outputDimensions))
        }
    }
    
    func forward(_ x: MLXArray) -> MLXArray {
        var output = MLX.matmul(x, weight.transposed(-2, -1))
        if let b = bias {
            output = output + b
        }
        return output
    }
}

class Conv2d {
    var weight: MLXArray
    var bias: MLXArray
    let inputChannels: Int
    let outputChannels: Int
    let kernelSize: Int
    let stride: Int
    let padding: Int
    
    init(inputChannels: Int, outputChannels: Int, kernelSize: Int, stride: Int = 1, padding: Int = 0) {
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.kernelSize = kernelSize
        self.stride = stride
        self.padding = padding
        
        let scale = sqrt(1.0 / Float(inputChannels * kernelSize * kernelSize))
        let wData = (0..<outputChannels * inputChannels * kernelSize * kernelSize).map { _ in Float.random(in: -scale...scale) }
        self.weight = MLXArray(wData).reshaped([outputChannels, inputChannels, kernelSize, kernelSize])
        self.bias = MLXArray([Float](repeating: 0, count: outputChannels))
    }
    
    func forward(_ x: MLXArray) -> MLXArray {
        let shape = x.shape
        let batch = shape[0]
        let inH = shape[1]
        let inW = shape[2]
        
        let outH = (inH + 2 * padding - kernelSize) / stride + 1
        let outW = (inW + 2 * padding - kernelSize) / stride + 1
        
        var output = [Float](repeating: 0, count: batch * outH * outW * outputChannels)
        
        let xData = x.asArray(Float.self)
        let wData = weight.asArray(Float.self)
        let bData = bias.asArray(Float.self)
        
        for b in 0..<batch {
            for oh in 0..<outH {
                for ow in 0..<outW {
                    for oc in 0..<outputChannels {
                        var sum = bData[oc]
                        for ic in 0..<inputChannels {
                            for kh in 0..<kernelSize {
                                for kw in 0..<kernelSize {
                                    let ih = oh * stride + kh - padding
                                    let iw = ow * stride + kw - padding
                                    if ih >= 0 && ih < inH && iw >= 0 && iw < inW {
                                        let xIdx = b * inH * inW * inputChannels + ih * inW * inputChannels + iw * inputChannels + ic
                                        let wIdx = oc * inputChannels * kernelSize * kernelSize + ic * kernelSize * kernelSize + kh * kernelSize + kw
                                        sum += xData[xIdx] * wData[wIdx]
                                    }
                                }
                            }
                        }
                        let outIdx = b * outH * outW * outputChannels + oh * outW * outputChannels + ow * outputChannels + oc
                        output[outIdx] = sum
                    }
                }
            }
        }
        
        return MLXArray(output).reshaped([batch, outH, outW, outputChannels])
    }
}

func gelu(_ x: MLXArray) -> MLXArray {
    return 0.5 * x * (1.0 + MLX.tanh(sqrt(2.0 / Float.pi) * (x + 0.044715 * x * x * x)))
}

func silu(_ x: MLXArray) -> MLXArray {
    return x * MLX.sigmoid(x)
}

func softmax(_ x: MLXArray, axis: Int) -> MLXArray {
    let maxVal = MLX.max(x, axis: axis, keepDims: true)
    let expX = MLX.exp(x - maxVal)
    let sumExp = MLX.sum(expX, axis: axis, keepDims: true)
    return expX / sumExp
}
