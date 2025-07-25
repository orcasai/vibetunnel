import Foundation
import Observation

/// Service for managing session-related API operations.
///
/// Provides high-level methods for interacting with terminal sessions through
/// the server API, including renaming and terminating sessions. Handles authentication
/// and error management for all session-related operations.
@MainActor
@Observable
final class SessionService {
    private let serverManager: ServerManager
    private let sessionMonitor: SessionMonitor

    init(serverManager: ServerManager, sessionMonitor: SessionMonitor) {
        self.serverManager = serverManager
        self.sessionMonitor = sessionMonitor
    }

    /// Rename a session
    func renameSession(sessionId: String, to newName: String) async throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SessionServiceError.invalidName
        }

        guard let url =
            URL(string: "\(URLConstants.localServerBase):\(serverManager.port)\(APIEndpoints.sessions)/\(sessionId)")
        else {
            throw SessionServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(NetworkConstants.contentTypeJSON, forHTTPHeaderField: NetworkConstants.contentTypeHeader)
        request.setValue(NetworkConstants.localhost, forHTTPHeaderField: NetworkConstants.hostHeader)
        try serverManager.authenticate(request: &request)

        let body = ["name": trimmedName]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw SessionServiceError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // Force refresh the session monitor to see the update immediately
        await sessionMonitor.refresh()
    }

    /// Terminate a session
    ///
    /// This method performs a two-step termination process:
    /// 1. Sends a DELETE request to the server to kill the process
    /// 2. Closes the terminal window if it was opened by VibeTunnel
    ///
    /// The window closing step is crucial for user experience - it prevents
    /// the accumulation of empty terminal windows after killing processes.
    /// However, it only closes windows that VibeTunnel opened via AppleScript,
    /// not windows from external `vt` attachments.
    ///
    /// - Parameter sessionId: The ID of the session to terminate
    /// - Throws: `SessionServiceError` if the termination request fails
    ///
    /// - Note: The server implements graceful termination (SIGTERM → SIGKILL)
    ///         with a 3-second timeout before force-killing processes.
    func terminateSession(sessionId: String) async throws {
        guard let url =
            URL(string: "\(URLConstants.localServerBase):\(serverManager.port)\(APIEndpoints.sessions)/\(sessionId)")
        else {
            throw SessionServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(NetworkConstants.localhost, forHTTPHeaderField: NetworkConstants.hostHeader)
        try serverManager.authenticate(request: &request)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 204
        else {
            throw SessionServiceError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // After successfully terminating the session, close the window if we opened it.
        // This is the key feature that prevents orphaned terminal windows.
        //
        // Why this matters:
        // - Simple commands (like `ls`) exit naturally and close their windows
        // - Long-running processes (like `claude`) leave windows open when killed
        // - This ensures consistent behavior - windows always close when sessions end
        //
        // The check inside closeWindowIfOpenedByUs ensures we only close windows
        // that VibeTunnel created, not externally attached sessions.
        _ = await MainActor.run {
            WindowTracker.shared.closeWindowIfOpenedByUs(for: sessionId)
        }

        // The session monitor will automatically update via its polling mechanism
    }

    /// Send input text to a session
    func sendInput(to sessionId: String, text: String) async throws {
        guard serverManager.isRunning else {
            throw SessionServiceError.serverNotRunning
        }

        guard let url =
            URL(
                string: "\(URLConstants.localServerBase):\(serverManager.port)\(APIEndpoints.sessions)/\(sessionId)/input"
            )
        else {
            throw SessionServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(NetworkConstants.contentTypeJSON, forHTTPHeaderField: NetworkConstants.contentTypeHeader)
        request.setValue(NetworkConstants.localhost, forHTTPHeaderField: NetworkConstants.hostHeader)
        try serverManager.authenticate(request: &request)

        let body = ["text": text]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 204
        else {
            throw SessionServiceError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Send a key command to a session
    func sendKey(to sessionId: String, key: String) async throws {
        guard serverManager.isRunning else {
            throw SessionServiceError.serverNotRunning
        }

        guard let url =
            URL(
                string: "\(URLConstants.localServerBase):\(serverManager.port)\(APIEndpoints.sessions)/\(sessionId)/input"
            )
        else {
            throw SessionServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(NetworkConstants.contentTypeJSON, forHTTPHeaderField: NetworkConstants.contentTypeHeader)
        request.setValue(NetworkConstants.localhost, forHTTPHeaderField: NetworkConstants.hostHeader)
        try serverManager.authenticate(request: &request)

        let body = ["key": key]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 204
        else {
            throw SessionServiceError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Create a new session
    func createSession(
        command: [String],
        workingDir: String,
        name: String? = nil,
        titleMode: String = "dynamic",
        spawnTerminal: Bool = false,
        cols: Int = 120,
        rows: Int = 30
    )
        async throws -> String
    {
        guard serverManager.isRunning else {
            throw SessionServiceError.serverNotRunning
        }

        guard let url = URL(string: "\(URLConstants.localServerBase):\(serverManager.port)\(APIEndpoints.sessions)")
        else {
            throw SessionServiceError.invalidURL
        }

        var body: [String: Any] = [
            "command": command,
            "workingDir": workingDir,
            "titleMode": titleMode
        ]

        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            body["name"] = name
        }

        if spawnTerminal {
            body["spawn_terminal"] = true
        } else {
            // Web sessions need terminal dimensions
            body["cols"] = cols
            body["rows"] = rows
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(NetworkConstants.contentTypeJSON, forHTTPHeaderField: NetworkConstants.contentTypeHeader)
        request.setValue(NetworkConstants.localhost, forHTTPHeaderField: NetworkConstants.hostHeader)
        try serverManager.authenticate(request: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            var errorMessage = "Failed to create session"
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorData["error"] as? String
            {
                errorMessage = error
            }
            throw SessionServiceError.createFailed(message: errorMessage)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["sessionId"] as? String
        else {
            throw SessionServiceError.invalidResponse
        }

        // Refresh session list
        await sessionMonitor.refresh()

        return sessionId
    }
}

/// Errors that can occur during session service operations
/// Errors that can occur during session service operations.
///
/// Provides detailed error cases for session management failures,
/// including validation errors, network issues, and server state problems.
enum SessionServiceError: LocalizedError {
    case invalidName
    case invalidURL
    case serverNotRunning
    case requestFailed(statusCode: Int)
    case createFailed(message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidName:
            ErrorMessages.sessionNameEmpty
        case .invalidURL:
            ErrorMessages.invalidServerURL
        case .serverNotRunning:
            ErrorMessages.serverNotRunning
        case .requestFailed(let statusCode):
            "Request failed with status code: \(statusCode)"
        case .createFailed(let message):
            message
        case .invalidResponse:
            ErrorMessages.invalidServerResponse
        }
    }
}
