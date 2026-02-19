import Foundation

class Qwen3Tokenizer {
    private var vocab: [String: Int] = [:]
    private var idToToken: [Int: String] = [:]
    private var merges: [(String, String)] = []

    // Byte-level fallback map (GPT-2/Qwen2 style: byte i → Unicode char)
    private static let byteDecoder: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        // Printable ASCII 33–126, 161–172, 174–255 map to themselves
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }
        for (b, c) in zip(bs, cs) {
            if let scalar = Unicode.Scalar(c), let byte = UInt8(exactly: b) {
                map[Character(scalar)] = byte
            }
        }
        return map
    }()

    var bosTokenId: Int = 151644
    var eosTokenId: Int = 151645
    var padTokenId: Int = 151643

    init(directory: URL) throws {
        // Prefer vocab.json + merges.txt (Qwen2 BPE format)
        let vocabPath  = directory.appendingPathComponent("vocab.json")
        let mergesPath = directory.appendingPathComponent("merges.txt")
        let tokenizerJsonPath = directory.appendingPathComponent("tokenizer.json")

        if FileManager.default.fileExists(atPath: vocabPath.path) {
            try loadVocabJSON(vocabPath)
            if FileManager.default.fileExists(atPath: mergesPath.path) {
                try loadMergesTxt(mergesPath)
            }
        } else if FileManager.default.fileExists(atPath: tokenizerJsonPath.path) {
            // Fallback: tokenizer.json with model.vocab field
            try loadTokenizerJSON(tokenizerJsonPath)
        } else {
            throw TokenizerError.fileNotFound(vocabPath.path)
        }

        // Determine special token IDs from loaded vocab (with sensible Qwen2 defaults)
        bosTokenId = vocab["<|im_start|>"] ?? vocab["<|begin_of_text|>"] ?? vocab["<s>"] ?? 151644
        eosTokenId = vocab["<|im_end|>"]   ?? vocab["<|end_of_text|>"]   ?? vocab["</s>"] ?? 151645
        padTokenId = vocab["<|endoftext|>"] ?? vocab["<|pad|>"] ?? vocab["<pad>"] ?? 151643
    }

    // MARK: - Loaders

    private func loadVocabJSON(_ path: URL) throws {
        let data = try Data(contentsOf: path)
        guard let vocabDict = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw TokenizerError.invalidFormat
        }
        self.vocab = vocabDict
        for (token, id) in vocabDict {
            idToToken[id] = token
        }
    }

    private func loadMergesTxt(_ path: URL) throws {
        let contents = try String(contentsOf: path, encoding: .utf8)
        self.merges = contents.split(separator: "\n").compactMap { line in
            let s = String(line)
            if s.hasPrefix("#") { return nil }
            let parts = s.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    private func loadTokenizerJSON(_ path: URL) throws {
        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TokenizerError.invalidFormat
        }

        if let model = json["model"] as? [String: Any] {
            if let vocabDict = model["vocab"] as? [String: Int] {
                self.vocab = vocabDict
                for (token, id) in vocabDict {
                    idToToken[id] = token
                }
            }
            if let mergesList = model["merges"] as? [String] {
                self.merges = mergesList.compactMap { merge in
                    let parts = merge.split(separator: " ", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
            }
        }

        // Load added_tokens (special tokens) into vocab
        if let addedTokens = json["added_tokens"] as? [[String: Any]] {
            for tokenInfo in addedTokens {
                if let token = tokenInfo["content"] as? String,
                   let id = tokenInfo["id"] as? Int {
                    vocab[token] = id
                    idToToken[id] = token
                }
            }
        }
    }

    // MARK: - Encoding

    /// Encode text and return as Int32 array (for building prompt token sequences).
    func encodeToInt32(_ text: String) -> [Int32] {
        return encode(text).map { Int32($0) }
    }

    func encode(_ text: String) -> [Int] {
        var tokens: [Int] = []

        // GPT-2/Qwen2 regex split pattern
        let pattern = #"('s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return Array(text.utf8).map { Int($0) }
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let piece = String(text[matchRange])
            // Encode piece to bytes, then map each byte to GPT-2 byte-level unicode chars
            let byteEncoded = encodeBytes(piece)
            if let tokenId = vocab[byteEncoded] {
                tokens.append(tokenId)
            } else {
                let subTokens = bpeMerge(byteEncoded)
                tokens.append(contentsOf: subTokens)
            }
        }

        return tokens
    }

    /// Map a raw string piece to GPT-2-style byte-level unicode characters.
    private func encodeBytes(_ piece: String) -> String {
        // GPT-2 byte-to-unicode: printable bytes stay, others map to Unicode offsets
        // We need the inverse of byteDecoder: byte → unicode char
        var result = ""
        for byte in piece.utf8 {
            let b = Int(byte)
            // Use the cs mapping: bytes 33–126 stay, 161–172, 174–255 stay,
            // remaining 0–32, 127–160, 173 map to 256+n in order
            result.append(byteToUnicodeChar(b))
        }
        return result
    }

    private static let byteToUnicode: [UInt8: Character] = {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) {
            if let scalar = Unicode.Scalar(c) {
                map[UInt8(b)] = Character(scalar)
            }
        }
        return map
    }()

    private func byteToUnicodeChar(_ byte: Int) -> Character {
        return Self.byteToUnicode[UInt8(byte)] ?? Character(Unicode.Scalar(byte)!)
    }

    private func bpeMerge(_ byteEncoded: String) -> [Int] {
        // Split into individual Unicode "chars" (each char = one GPT-2 BPE unit)
        var tokens = byteEncoded.map { String($0) }

        for (a, b) in merges {
            var i = 0
            while i < tokens.count - 1 {
                if tokens[i] == a && tokens[i + 1] == b {
                    tokens[i] = a + b
                    tokens.remove(at: i + 1)
                } else {
                    i += 1
                }
            }
        }

        return tokens.compactMap { vocab[$0] }
    }

    // MARK: - Decoding

    func decode(_ ids: [Int]) -> String {
        // Collect byte-level characters, then decode to string
        var byteChars = ""
        for id in ids {
            guard let token = idToToken[id] else { continue }
            // Skip special tokens
            if token.hasPrefix("<|") && token.hasSuffix("|>") { continue }
            byteChars += token
        }
        // Convert byte-level unicode back to bytes, then to UTF-8 string
        return decodeByteLevelString(byteChars)
    }

    private func decodeByteLevelString(_ s: String) -> String {
        var bytes: [UInt8] = []
        for char in s {
            if let byte = Self.byteDecoder[char] {
                bytes.append(byte)
            }
            // Chars not in the byte decoder are skipped (shouldn't happen with valid tokens)
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    var vocabSize: Int {
        return vocab.count
    }
}

enum TokenizerError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Tokenizer file not found: \(path)"
        case .invalidFormat:
            return "Invalid tokenizer format"
        }
    }
}
