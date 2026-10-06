// Prints NLTokenizer's sentence split for each JSON string read from stdin, as
// JSON: [{"input": "...", "sentences": ["...", ...]}]. Each sentence trimmed
// and empty ones dropped, as StructurePolish.split uses them. Used by
// make_golden.py to pin windows/Talkflow.Core/Text/SentenceSplitter.cs.
import Foundation
import NaturalLanguage

let data = FileHandle.standardInput.readDataToEndOfFile()
let inputs = try! JSONSerialization.jsonObject(with: data) as! [String]
var out: [[String: Any]] = []
for text in inputs {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    let sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        .map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    out.append(["input": text, "sentences": sentences])
}
let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
