/// The title of a document imported from a file (PQ2): the file name without its extension, without the
/// whitespace around it. An empty result shows as "Untitled document" through `displayTitle`.
///
/// Only the last extension goes ("Rechnung 2024.03.pdf" gives "Rechnung 2024.03"). A last part with
/// whitespace in it is no extension ("Bericht v1.2 final" stays), nor is an empty one ("Notiz." stays). A
/// name that is only an extension (".pdf") gives an empty title.
public func importTitle(fromFileName fileName: String) -> String {
    let name = normalizedTitle(fileName)
    guard let dot = name.lastIndex(of: ".") else { return name }
    let fileExtension = name[name.index(after: dot)...]
    guard !fileExtension.isEmpty, !fileExtension.contains(where: \.isWhitespace) else { return name }
    return normalizedTitle(String(name[..<dot]))
}
