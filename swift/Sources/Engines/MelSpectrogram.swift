import Foundation
import MLX
import Accelerate

class MelSpectrogram {
    let sampleRate: Int
    let nFft: Int
    let hopLength: Int
    let nMels: Int
    let fMin: Float
    let fMax: Float
    
    private let hannWindow: [Float]
    private let melFilterbank: [[Float]]
    private let fftSetup: OpaquePointer
    private let fftSize: Int
    private let fftLog2n: vDSP_Length
    
    init(
        sampleRate: Int = 16000,
        nFft: Int = 400,
        hopLength: Int = 160,
        nMels: Int = 128,
        fMin: Float = 0.0,
        fMax: Float? = nil
    ) {
        self.sampleRate = sampleRate
        self.nFft = nFft
        self.hopLength = hopLength
        self.nMels = nMels
        self.fMin = fMin
        self.fMax = fMax ?? Float(sampleRate) / 2.0
        
        self.fftSize = nFft
        self.fftLog2n = vDSP_Length(log2(Float(fftSize)))
        
        self.hannWindow = Self.createHannWindow(length: nFft)
        self.melFilterbank = Self.createMelFilterbank(
            nFft: nFft,
            nMels: nMels,
            sampleRate: sampleRate,
            fMin: self.fMin,
            fMax: self.fMax
        )
        
        // Create FFT setup (cached for reuse)
        self.fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))!
    }
    
    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }
    
    func extract(samples: [Float]) -> [[Float]] {
        let padded = padReflect(samples, padding: nFft / 2)
        let frames = frameSignal(padded, frameLength: nFft, hopLength: hopLength)
        
        var melSpec: [[Float]] = []
        melSpec.reserveCapacity(frames.count)
        
        var windowedFrame = [Float](repeating: 0, count: fftSize)
        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)
        
        for frame in frames {
            // Apply Hann window
            vDSP_vmul(frame, 1, hannWindow, 1, &windowedFrame, 1, vDSP_Length(fftSize))
            
            // Perform real FFT using vDSP_fft_zrip
            windowedFrame.withUnsafeMutableBufferPointer { windowedPtr in
                realPart.withUnsafeMutableBufferPointer { realPtr in
                    imagPart.withUnsafeMutableBufferPointer { imagPtr in
                        var splitComplex = DSPSplitComplex(
                            realp: realPtr.baseAddress!,
                            imagp: imagPtr.baseAddress!
                        )
                        
                        // Pack the real signal
                        vDSP_ctoz(
                            UnsafePointer<DSPComplex>(OpaquePointer(windowedPtr.baseAddress!)),
                            2,
                            &splitComplex,
                            1,
                            vDSP_Length(fftSize / 2)
                        )
                        
                        // Perform FFT
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, fftLog2n, FFTDirection(kFFTDirection_Forward))
                        
                        // Scale factor for vDSP FFT
                        let scale = 1.0 / Float(fftSize)
                        vDSP_vsmul(splitComplex.realp, 1, [scale], splitComplex.realp, 1, vDSP_Length(fftSize / 2))
                        vDSP_vsmul(splitComplex.imagp, 1, [scale], splitComplex.imagp, 1, vDSP_Length(fftSize / 2))
                    }
                }
            }
            
            // Compute magnitude squared (DC, Nyquist, and rest)
            let nBins = nFft / 2 + 1
            var magnitude = [Float](repeating: 0, count: nBins)
            
            // DC component
            magnitude[0] = realPart[0] * realPart[0]
            
            // Middle bins
            for i in 1..<(nBins - 1) {
                magnitude[i] = realPart[i] * realPart[i] + imagPart[i] * imagPart[i]
            }
            
            // Nyquist
            magnitude[nBins - 1] = imagPart[0] * imagPart[0]
            
            // Apply mel filterbank
            var melBand = [Float](repeating: 0, count: nMels)
            for melIdx in 0..<nMels {
                var sum: Float = 0
                let filter = melFilterbank[melIdx]
                vDSP_dotpr(magnitude, 1, filter, 1, &sum, vDSP_Length(nBins))
                melBand[melIdx] = max(sum, 1e-10)
            }
            
            // Log scale
            var logMelBand = [Float](repeating: 0, count: nMels)
            for i in 0..<nMels {
                logMelBand[i] = log(melBand[i])
            }
            
            melSpec.append(logMelBand)
        }
        
        return melSpec
    }
    
    func extractMLX(samples: [Float]) -> MLXArray {
        let melSpec = extract(samples: samples)
        return Self.array2DToMLX(melSpec)
    }
    
    private static func array2DToMLX(_ array: [[Float]]) -> MLXArray {
        guard !array.isEmpty else { return MLXArray([Float]()) }
        let flat = array.flatMap { $0 }
        let nFrames = array.count
        let nMels = array.first?.count ?? 0
        return MLXArray(flat).reshaped([nFrames, nMels])
    }
    
    private static func createHannWindow(length: Int) -> [Float] {
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return window
    }
    
    private static func createMelFilterbank(
        nFft: Int,
        nMels: Int,
        sampleRate: Int,
        fMin: Float,
        fMax: Float
    ) -> [[Float]] {
        let nFreqs = nFft / 2 + 1
        
        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)
        
        let melPoints = linspace(melMin, melMax, nMels + 2)
        var hzPoints: [Float] = []
        for mel in melPoints {
            hzPoints.append(melToHz(mel))
        }
        
        var binPoints: [Int] = []
        let sampleRateFloat = Float(sampleRate)
        let nFftFloat = Float(nFft + 1)
        for hz in hzPoints {
            let bin = Int(floor(nFftFloat * hz / sampleRateFloat))
            binPoints.append(bin)
        }
        
        var filterbank: [[Float]] = []
        for _ in 0..<nMels {
            filterbank.append([Float](repeating: 0, count: nFreqs))
        }
        
        for i in 0..<nMels {
            let leftBin = binPoints[i]
            let centerBin = binPoints[i + 1]
            let rightBin = binPoints[i + 2]
            
            let leftBound = max(0, leftBin)
            let centerBound = min(nFreqs, centerBin)
            let rightBound = min(nFreqs, rightBin)
            
            if centerBin > leftBin {
                let denom1 = Float(centerBin - leftBin)
                for j in leftBound..<centerBound {
                    filterbank[i][j] = Float(j - leftBin) / denom1
                }
            }
            if rightBin > centerBin {
                let denom2 = Float(rightBin - centerBin)
                for j in centerBound..<rightBound {
                    filterbank[i][j] = Float(rightBin - j) / denom2
                }
            }
        }
        
        return filterbank
    }
    
    private static func hzToMel(_ hz: Float) -> Float {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }
    
    private static func melToHz(_ mel: Float) -> Float {
        return 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }
    
    private static func linspace(_ start: Float, _ end: Float, _ count: Int) -> [Float] {
        guard count > 1 else { return [start] }
        let step = (end - start) / Float(count - 1)
        return (0..<count).map { start + Float($0) * step }
    }
    
    private func padReflect(_ samples: [Float], padding: Int) -> [Float] {
        let length = samples.count
        var padded = [Float](repeating: 0, count: length + 2 * padding)
        
        for i in 0..<padding {
            padded[padding - 1 - i] = samples[min(i + 1, length - 1)]
        }
        for i in 0..<length {
            padded[padding + i] = samples[i]
        }
        for i in 0..<padding {
            padded[padding + length + i] = samples[max(length - 2 - i, 0)]
        }
        
        return padded
    }
    
    private func frameSignal(_ samples: [Float], frameLength: Int, hopLength: Int) -> [[Float]] {
        let length = samples.count
        let nFrames = max(0, (length - frameLength) / hopLength + 1)
        
        var frames: [[Float]] = []
        frames.reserveCapacity(nFrames)
        
        for i in 0..<nFrames {
            let start = i * hopLength
            frames.append(Array(samples[start..<start + frameLength]))
        }
        
        return frames
    }
}
