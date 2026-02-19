import Foundation

class Qwen3Tokenizer {
    private var vocab: [String: Int] = [:]
    private var idToToken: [Int: String] = [:]
    private var merges: [(String, String)] = []
    
    var bosTokenId: Int = 1
    var eosTokenId: Int = 2
    var padTokenId: Int = 0
    
    init(directory: URL) throws {
        let tokenizerPath = directory.appendingPathComponent("tokenizer.json")
        
        if FileManager.default.fileExists(atPath: tokenizerPath.path) {
            try loadTokenizerJSON(tokenizerPath)
        } else {
            throw TokenizerError.fileNotFound(tokenizerPath.path)
        }
        
        bosTokenId = vocab["<|begin_of_text|>"] ?? vocab["<s>"] ?? 1
        eosTokenId = vocab["<|end_of_text|>"] ?? vocab["</s>"] ?? 2
        padTokenId = vocab["<|pad|>"] ?? vocab["<pad>"] ?? 0
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
        
        if vocab.isEmpty, let addedTokens = json["added_tokens"] as? [[String: Any]] {
            for tokenInfo in addedTokens {
                if let token = tokenInfo["content"] as? String,
                   let id = tokenInfo["id"] as? Int {
                    vocab[token] = id
                    idToToken[id] = token
                }
            }
        }
    }
    
    func encode(_ text: String) -> [Int] {
        var tokens: [Int] = []
        
        let pattern = #"('s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return Array(text.utf8).map { Int($0) }
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let piece = String(text[matchRange])
            
            if let tokenId = vocab[piece] {
                tokens.append(tokenId)
            } else {
                let subTokens = encodePiece(piece)
                tokens.append(contentsOf: subTokens)
            }
        }
        
        return tokens
    }
    
    private func encodePiece(_ piece: String) -> [Int] {
        var tokens = Array(piece).map { String($0) }
        
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
    
    func decode(_ ids: [Int]) -> String {
        var result = ""
        for id in ids {
            if let token = idToToken[id] {
                result += decodeToken(token)
            }
        }
        return result
    }
    
    private func decodeToken(_ token: String) -> String {
        if token.hasPrefix("<|") && token.hasSuffix("|>") {
            return ""
        }
        
        if token.hasPrefix("Ġ") {
            return " " + String(token.dropFirst())
        }
        
        return token
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
