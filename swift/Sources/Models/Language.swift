import Foundation

struct Language: Identifiable, Hashable {
    let id: String
    let name: String
    
    static let all: [Language] = [
        Language(id: "auto", name: "Auto-detect"),
        Language(id: "en", name: "English"),
        Language(id: "es", name: "Spanish"),
        Language(id: "fr", name: "French"),
        Language(id: "de", name: "German"),
        Language(id: "it", name: "Italian"),
        Language(id: "pt", name: "Portuguese"),
        Language(id: "nl", name: "Dutch"),
        Language(id: "pl", name: "Polish"),
        Language(id: "ru", name: "Russian"),
        Language(id: "tr", name: "Turkish"),
        Language(id: "zh", name: "Chinese"),
        Language(id: "ja", name: "Japanese"),
        Language(id: "ko", name: "Korean"),
        Language(id: "hi", name: "Hindi"),
        Language(id: "ar", name: "Arabic"),
        Language(id: "sv", name: "Swedish"),
        Language(id: "da", name: "Danish"),
        Language(id: "fi", name: "Finnish"),
        Language(id: "no", name: "Norwegian"),
        Language(id: "el", name: "Greek"),
        Language(id: "he", name: "Hebrew"),
        Language(id: "id", name: "Indonesian"),
        Language(id: "vi", name: "Vietnamese"),
        Language(id: "th", name: "Thai"),
        Language(id: "cs", name: "Czech"),
        Language(id: "hu", name: "Hungarian"),
        Language(id: "ro", name: "Romanian"),
        Language(id: "ca", name: "Catalan"),
        Language(id: "uk", name: "Ukrainian")
    ].sorted { $0.name < $1.name }
}
