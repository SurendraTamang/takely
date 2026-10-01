import ProjectKit

/// Work done after a recording stops and before it's exported — e.g. a transcript and an AI title (Takely Pro).
/// It writes its results into the bundle (`transcript.json`, named markers, the manifest's title and summary),
/// which the export then picks up. A failure is logged and never blocks the export.
public protocol PostProcessor: Sendable {
    func process(_ bundle: ProjectBundle, progress: @escaping @Sendable (Double) -> Void) async throws
}
