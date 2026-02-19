import Foundation
import MLX

class KVCache {
    private var kCache: [MLXArray?] = []
    private var vCache: [MLXArray?] = []
    private let maxLayers: Int
    
    init(maxLayers: Int = 32) {
        self.maxLayers = maxLayers
        kCache = Array(repeating: nil, count: maxLayers)
        vCache = Array(repeating: nil, count: maxLayers)
    }
    
    func get(layer: Int) -> (MLXArray?, MLXArray?) {
        guard layer < maxLayers else { return (nil, nil) }
        return (kCache[layer], vCache[layer])
    }
    
    func update(k: MLXArray, v: MLXArray, layer: Int) -> (MLXArray, MLXArray) {
        guard layer < maxLayers else { return (k, v) }
        
        if let existingK = kCache[layer], let existingV = vCache[layer] {
            // Concatenate along sequence dimension (axis 2)
            kCache[layer] = concatenated([existingK, k], axis: 2)
            vCache[layer] = concatenated([existingV, v], axis: 2)
        } else {
            kCache[layer] = k
            vCache[layer] = v
        }
        
        return (kCache[layer]!, vCache[layer]!)
    }
    
    func clear() {
        for i in 0..<maxLayers {
            kCache[i] = nil
            vCache[i] = nil
        }
    }
    
    var cacheSize: Int {
        return kCache.compactMap { $0 }.count
    }
}
