import Foundation

/// Reads and writes the app's own project format: pretty-printed JSON with the `.aeproj` extension.
/// Edits are non-destructive; the project only references audio files by path.
public enum ProjectFile {
    public static let fileExtension = "aeproj"

    public static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    public static func decode(_ data: Data) throws -> Project {
        try JSONDecoder().decode(Project.self, from: data)
    }

    public static func write(_ project: Project, to url: URL) throws {
        try encode(project).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Project {
        try decode(Data(contentsOf: url))
    }
}
