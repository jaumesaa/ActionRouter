import ArgumentParser
import Foundation

struct FetchModel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch-model",
        abstract: "Download the recommended multilingual embedding model (int8 Core ML conversion of intfloat/multilingual-e5-small, MIT)."
    )

    static let defaultURL =
        "https://github.com/jaumesaa/ActionRouter/releases/latest/download/MultilingualE5Small-Int8.zip"

    @Option(name: .long, help: "Asset URL (a zip containing the .mlpackage and tokenizer/).")
    var url: String = FetchModel.defaultURL

    @Option(name: [.customShort("t"), .customLong("to")], help: "Destination directory.")
    var to: String

    func run() async throws {
        guard let remote = URL(string: url) else {
            throw ValidationError("Invalid URL: \(url)")
        }
        let destination = URL(fileURLWithPath: to, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )

        FileHandle.standardError.write(Data("downloading \(remote.absoluteString)…\n".utf8))
        let (temporary, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ValidationError("Download failed with HTTP \(http.statusCode)")
        }

        // ditto preserves the .mlpackage bundle structure when extracting.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", temporary.path, destination.path]
        try unzip.run()
        unzip.waitUntilExit()
        try? FileManager.default.removeItem(at: temporary)
        guard unzip.terminationStatus == 0 else {
            throw ValidationError("Could not extract archive (ditto exit \(unzip.terminationStatus))")
        }

        let model = destination.appendingPathComponent("MultilingualE5Small-Int8.mlpackage")
        let tokenizer = destination.appendingPathComponent("tokenizer/tokenizer.json")
        guard FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: tokenizer.path) else {
            throw ValidationError("Archive did not contain the expected model/tokenizer layout")
        }
        print("model ready at \(destination.path)")
        print("try: actionrouter route --actions Examples/sample-actions.json --e5-dir \(destination.path) \"convertir a wav\"")
    }
}
