import Foundation
import Security

private struct RemoteGxserverConnection {
  let baseURL: String
  let localPort: Int
  let remoteMachineId: String
  let token: String
  let tunnelProcess: Process
}

private struct RemoteProcessResult {
  let exitCode: Int32
  let stderr: String
  let stdout: String
}

private struct RemoteSshAskpassScript {
  let directory: URL
  let script: URL
}

final class RemoteGxserverClient {
  static let shared = RemoteGxserverClient()

  private static let keychainService = "com.madda.ghostex.remote-gxserver-token"
  private static let sshPasswordKeychainService = "com.madda.ghostex.remote-ssh-password"
  private let lock = NSLock()
  private var connections: [String: RemoteGxserverConnection] = [:]
  private var presentationSubscriptions: [String: URLSessionWebSocketTask] = [:]

  private init() {}

  /*
   CDXC:RemoteMachines 2026-06-03-00:18:
   Remote connection setup is native-owned: Swift runs SSH, starts or checks
   gxserver on the remote host, reads the remote token over SSH, stores that
   token in Keychain, and keeps the local tunnel process. React receives status
   only and must not read or persist remote bearer tokens.
   */
  func connect(_ command: RemoteGxserverConnect) async -> HostEvent {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let event = self.connectSynchronously(command)
        continuation.resume(returning: event)
      }
    }
  }

  func saveSshPassword(_ command: RemoteSshPasswordSave) async -> HostEvent {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let event = self.saveSshPasswordSynchronously(command)
        continuation.resume(returning: event)
      }
    }
  }

  func request(_ command: RemoteGxserverRequest) async -> HostEvent {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let connection = try self.connection(for: command.remoteMachineId)
          let response = try self.performRequest(command, connection: connection)
          continuation.resume(returning: .remoteGxserverResponse(
            remoteMachineId: command.remoteMachineId,
            requestId: command.requestId,
            path: command.path,
            ok: (200..<300).contains(response.statusCode),
            statusCode: response.statusCode,
            bodyJson: response.body,
            error: nil
          ))
        } catch {
          continuation.resume(returning: .remoteGxserverResponse(
            remoteMachineId: command.remoteMachineId,
            requestId: command.requestId,
            path: command.path,
            ok: false,
            statusCode: nil,
            bodyJson: nil,
            error: error.localizedDescription
          ))
        }
      }
    }
  }

  func subscribePresentation(
    _ command: RemoteGxserverPresentationSubscribe,
    eventHandler: @escaping (HostEvent) -> Void
  ) async -> HostEvent {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let connection = try self.connection(for: command.remoteMachineId)
          try self.subscribePresentationSynchronously(
            command,
            connection: connection,
            eventHandler: eventHandler
          )
          continuation.resume(returning: .remoteGxserverStatus(
            remoteMachineId: command.remoteMachineId,
            payloadJson: self.statusPayloadJson([
              "message": "Remote presentation subscription started.",
              "ok": true,
              "requestId": command.requestId,
              "state": "presentationSubscribed",
            ])
          ))
        } catch {
          continuation.resume(returning: .remoteGxserverStatus(
            remoteMachineId: command.remoteMachineId,
            payloadJson: self.statusPayloadJson([
              "message": error.localizedDescription,
              "ok": false,
              "requestId": command.requestId,
              "state": "presentationSubscribeFailed",
            ])
          ))
        }
      }
    }
  }

  func connectingStatus(remoteMachineId: String, requestId: String) -> HostEvent {
    .remoteGxserverStatus(
      remoteMachineId: remoteMachineId,
      payloadJson: statusPayloadJson([
        "message": "Connecting to remote gxserver over SSH...",
        "ok": true,
        "requestId": requestId,
        "state": "connecting",
      ])
    )
  }

  private func saveSshPasswordSynchronously(_ command: RemoteSshPasswordSave) -> HostEvent {
    let remoteMachineId = command.remoteMachineId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !remoteMachineId.isEmpty else {
      return .remoteSshPasswordSaveResult(
        remoteMachineId: command.remoteMachineId,
        requestId: command.requestId,
        ok: false,
        hasPassword: false,
        error: "Remote machine id is missing."
      )
    }
    do {
      let password = command.password
      /*
       CDXC:RemoteMachines 2026-06-09-18:23:
       User-provided SSH passwords are never written to Remote settings or
       passed as SSH command arguments. Save non-empty values in macOS Keychain
       under the remote machine id, and treat an empty save as credential
       removal so users can clear password auth without editing Keychain.
       */
      if password.isEmpty {
        try deleteSshPasswordFromKeychain(remoteMachineId: remoteMachineId)
        return .remoteSshPasswordSaveResult(
          remoteMachineId: remoteMachineId,
          requestId: command.requestId,
          ok: true,
          hasPassword: false,
          error: nil
        )
      }
      try storeSshPasswordInKeychain(password, remoteMachineId: remoteMachineId)
      return .remoteSshPasswordSaveResult(
        remoteMachineId: remoteMachineId,
        requestId: command.requestId,
        ok: true,
        hasPassword: true,
        error: nil
      )
    } catch {
      return .remoteSshPasswordSaveResult(
        remoteMachineId: remoteMachineId,
        requestId: command.requestId,
        ok: false,
        hasPassword: keychainHasSshPassword(remoteMachineId: remoteMachineId),
        error: "macOS Keychain could not save the SSH password."
      )
    }
  }

  private func connectSynchronously(_ command: RemoteGxserverConnect) -> HostEvent {
    guard !command.remoteMachineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return statusEvent(command, state: "invalid", ok: false, message: "Remote machine id is missing.")
    }
    guard !command.sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return statusEvent(command, state: "invalid", ok: false, message: "Remote SSH host is missing.")
    }

    let target = RemoteSshTarget(
      host: command.sshHost,
      identityFile: expandedLocalPath(command.identityFile),
      port: command.sshPort,
      sshPasswordAccount: keychainHasSshPassword(remoteMachineId: command.remoteMachineId)
        ? command.remoteMachineId
        : nil,
      user: command.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines)
    )

    terminateExistingConnection(remoteMachineId: command.remoteMachineId)

    let tokenResult = runSsh(
      target: target,
      remoteCommand: remoteTokenReadCommand(),
      timeoutSeconds: 18
    )
    if tokenResult.exitCode == 127 {
      if command.installApproved == true {
        let installResult = installBundledGxserverAndReadToken(target: target)
        if installResult.exitCode != 0 {
          return statusEvent(
            command,
            state: "installFailed",
            ok: false,
            message: sanitizedProcessFailure(defaultMessage: "Remote gxserver install failed.", result: installResult)
          )
        }
        return finishConnectWithTokenResult(command: command, target: target, tokenResult: installResult)
      }
      return statusEvent(
        command,
        state: "installApprovalRequired",
        ok: false,
        message: "gxserver is not installed on that machine. Ask before installing the remote gxserver package."
      )
    }
    if tokenResult.exitCode != 0 {
      return statusEvent(
        command,
        state: "sshFailed",
        ok: false,
        message: sanitizedProcessFailure(defaultMessage: "Remote gxserver SSH setup failed.", result: tokenResult)
      )
    }

    return finishConnectWithTokenResult(command: command, target: target, tokenResult: tokenResult)
  }

  private func finishConnectWithTokenResult(
    command: RemoteGxserverConnect,
    target: RemoteSshTarget,
    tokenResult: RemoteProcessResult
  ) -> HostEvent {
    let token = extractRemoteAuthToken(from: tokenResult.stdout)
    guard isValidAuthToken(token) else {
      return statusEvent(
        command,
        state: "tokenUnavailable",
        ok: false,
        message: "Remote gxserver token was not readable after SSH start."
      )
    }

    do {
      try storeTokenInKeychain(token, remoteMachineId: command.remoteMachineId)
    } catch {
      let status = OSStatus((error as NSError).code)
      let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
      return statusEvent(
        command,
        state: "keychainFailed",
        ok: false,
        message: "Could not store the remote gxserver token in Keychain (OSStatus \(status): \(detail))."
      )
    }

    do {
      let connection = try openTunnel(command: command, target: target, token: token)
      return statusEvent(
        command,
        state: "connected",
        ok: true,
        message: "Remote gxserver is connected.",
        extra: [
          "baseUrl": connection.baseURL,
          "localPort": connection.localPort,
          "protocolVersion": GxserverClient.protocolVersion,
        ]
      )
    } catch {
      return statusEvent(command, state: "tunnelFailed", ok: false, message: error.localizedDescription)
    }
  }

  private func remoteTokenReadCommand() -> String {
    """
    GHOSTEX_REMOTE_TOKEN_FILE="$HOME/.ghostex/gxserver/auth/token"; \
    GXSERVER_BIN="$(command -v gxserver 2>/dev/null || true)"; \
    GHOSTEX_BIN="$(command -v ghostex 2>/dev/null || true)"; \
    if [ -z "$GXSERVER_BIN" ] && [ -x "$HOME/.ghostex/gxserver/package/bin/gxserver" ]; then GXSERVER_BIN="$HOME/.ghostex/gxserver/package/bin/gxserver"; fi; \
    if [ -n "$GXSERVER_BIN" ]; then \
      "$GXSERVER_BIN" start --json >/dev/null 2>&1 || "$GXSERVER_BIN" start >/dev/null 2>&1 || true; \
    elif [ -n "$GHOSTEX_BIN" ]; then \
      "$GHOSTEX_BIN" server start --json >/dev/null 2>&1 || "$GHOSTEX_BIN" server start >/dev/null 2>&1 || true; \
    else \
      exit 127; \
    fi; \
    test -r "$GHOSTEX_REMOTE_TOKEN_FILE" || exit 126; \
    printf '__GHOSTEX_REMOTE_TOKEN_START__\\n'; \
    cat "$GHOSTEX_REMOTE_TOKEN_FILE"; \
    printf '\\n__GHOSTEX_REMOTE_TOKEN_END__\\n'
    """
  }

  private func installBundledGxserverAndReadToken(target: RemoteSshTarget) -> RemoteProcessResult {
    guard let packageURL = bundledGxserverPackageURL() else {
      return RemoteProcessResult(exitCode: 126, stderr: "Bundled gxserver package is unavailable.", stdout: "")
    }

    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostex-remote-gxserver-\(UUID().uuidString)", isDirectory: true)
    let archiveURL = tempDirectory.appendingPathComponent("gxserver.tar.gz")
    do {
      try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    } catch {
      return RemoteProcessResult(exitCode: 126, stderr: "Could not prepare gxserver upload archive.", stdout: "")
    }
    defer {
      try? FileManager.default.removeItem(at: tempDirectory)
    }

    /*
     CDXC:RemoteMachines 2026-06-02-23:38:
     Approved remote install uses the app-bundled gxserver package. Native
     creates a temporary archive, copies it over SSH, installs under
     ~/.ghostex/gxserver/package, and starts gxserver from that absolute path.

     CDXC:RemoteMachines 2026-06-08-19:12:
     Remote startup now runs through the user's zsh login+interactive
     environment so app-installed gxserver and public `ghostex server` installs
     can both find user-managed Node runtimes such as mise.
     */
    let tarResult = runProcess(
      executable: "/usr/bin/tar",
      arguments: ["-czf", archiveURL.path, "-C", packageURL.path, "."],
      timeoutSeconds: 60
    )
    if tarResult.exitCode != 0 {
      return RemoteProcessResult(exitCode: tarResult.exitCode, stderr: "Could not archive bundled gxserver package.", stdout: "")
    }

    let mkdirResult = runSsh(
      target: target,
      remoteCommand: "mkdir -p \"$HOME/.ghostex/gxserver\"",
      timeoutSeconds: 12
    )
    if mkdirResult.exitCode != 0 {
      return mkdirResult
    }

    let uploadResult = runScp(
      target: target,
      localPath: archiveURL.path,
      remotePath: "~/.ghostex/gxserver/gxserver-upload.tar.gz",
      timeoutSeconds: 120
    )
    if uploadResult.exitCode != 0 {
      return RemoteProcessResult(exitCode: uploadResult.exitCode, stderr: "Could not upload gxserver package over SSH.", stdout: "")
    }

    let installCommand = """
    set -eu; \
    rm -rf "$HOME/.ghostex/gxserver/package.tmp"; \
    mkdir -p "$HOME/.ghostex/gxserver/package.tmp" "$HOME/.local/bin"; \
    tar -xzf "$HOME/.ghostex/gxserver/gxserver-upload.tar.gz" -C "$HOME/.ghostex/gxserver/package.tmp"; \
    rm -rf "$HOME/.ghostex/gxserver/package"; \
    mv "$HOME/.ghostex/gxserver/package.tmp" "$HOME/.ghostex/gxserver/package"; \
    chmod +x "$HOME/.ghostex/gxserver/package/bin/gxserver" "$HOME/.ghostex/gxserver/package/bin/zmx" "$HOME/.ghostex/gxserver/package/bin/zehn" 2>/dev/null || true; \
    ln -sf "$HOME/.ghostex/gxserver/package/bin/gxserver" "$HOME/.local/bin/gxserver" 2>/dev/null || true; \
    \(remoteTokenReadCommand())
    """
    return runSsh(target: target, remoteCommand: installCommand, timeoutSeconds: 45)
  }

  private func bundledGxserverPackageURL() -> URL? {
    let resourceURL = Bundle.main.resourceURL
    let packageURL = resourceURL?.appendingPathComponent("Web/gxserver", isDirectory: true)
    if let packageURL, FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("bin/gxserver").path) {
      return packageURL
    }
    return nil
  }

  private func openTunnel(command: RemoteGxserverConnect, target: RemoteSshTarget, token: String) throws -> RemoteGxserverConnection {
    var lastError: Error?
    for _ in 0..<8 {
      let localPort = Int.random(in: 42000...58999)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      var arguments = ["-N"]
      arguments.append(contentsOf: sshClientOptions(target))
      arguments.append(contentsOf: [
        "-o", "ExitOnForwardFailure=yes",
        /*
         * CDXC:RemoteMachines 2026-06-13: Force a dedicated, non-multiplexed
         * connection for the tunnel. If the user's ~/.ssh/config enables
         * ControlMaster/ControlPath, an earlier gxserver SSH call opens a
         * persistent master; this `ssh -N -L` then attaches as a slave, hands
         * its forward to the master, and exits 0 immediately — tearing down the
         * -L listener so the health probe can never connect. Owning a private
         * connection keeps `-N` in the foreground holding the forward.
         */
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-L", "\(localPort):127.0.0.1:58744",
      ])
      arguments.append(contentsOf: sshTargetArguments(target))
      process.arguments = arguments
      appendTunnelDebugLog("attempt localPort=\(localPort) argv=/usr/bin/ssh \(arguments.joined(separator: " "))")
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = Pipe()
      process.standardError = Pipe()
      let askpass: RemoteSshAskpassScript?
      do {
        askpass = try makeSshAskpassScript(target: target)
      } catch {
        lastError = error
        continue
      }
      process.environment = sshAskpassEnvironment(askpass)
      defer {
        removeSshAskpassScript(askpass)
      }

      do {
        try process.run()
      } catch {
        lastError = error
        continue
      }

      Thread.sleep(forTimeInterval: 0.35)
      if !process.isRunning {
        let stderrText = drainPipeString(process.standardError)
        appendTunnelDebugLog("code1 tunnel exited early status=\(process.terminationStatus) stderr=\(stderrText.isEmpty ? "<empty>" : stderrText)")
        lastError = NSError(
          domain: "RemoteGxserverTunnel",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "SSH tunnel exited before remote gxserver became reachable.\(stderrText.isEmpty ? "" : " ssh: \(stderrText)")"]
        )
        continue
      }

      let baseURL = "http://127.0.0.1:\(localPort)"
      let health = waitForAuthenticatedHealth(baseURL: baseURL, token: token)
      if health.ok {
        let connection = RemoteGxserverConnection(
          baseURL: baseURL,
          localPort: localPort,
          remoteMachineId: command.remoteMachineId,
          token: token,
          tunnelProcess: process
        )
        lock.lock()
        connections[command.remoteMachineId] = connection
        lock.unlock()
        appendTunnelDebugLog("connected localPort=\(localPort)")
        return connection
      }

      process.terminate()
      process.waitUntilExit()
      var detailParts: [String] = []
      if let statusCode = health.lastStatusCode {
        detailParts.append("last health HTTP \(statusCode)")
      }
      if let probeError = health.lastErrorDescription {
        detailParts.append("probe error: \(probeError)")
      }
      let stderrText = drainPipeString(process.standardError)
      if !stderrText.isEmpty {
        detailParts.append("ssh: \(stderrText)")
      }
      let detail = detailParts.isEmpty ? "" : " (\(detailParts.joined(separator: "; ")))"
      appendTunnelDebugLog("code2 health unreachable localPort=\(localPort)\(detail)")
      lastError = NSError(
        domain: "RemoteGxserverTunnel",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "SSH tunnel opened, but remote gxserver health did not become reachable.\(detail)"]
      )
    }

    throw lastError ?? NSError(
      domain: "RemoteGxserverTunnel",
      code: 3,
      userInfo: [NSLocalizedDescriptionKey: "Could not open an SSH tunnel to remote gxserver."]
    )
  }

  private func subscribePresentationSynchronously(
    _ command: RemoteGxserverPresentationSubscribe,
    connection: RemoteGxserverConnection,
    eventHandler: @escaping (HostEvent) -> Void
  ) throws {
    guard var components = URLComponents(string: "\(connection.baseURL)/api/events") else {
      throw NSError(
        domain: "RemoteGxserverPresentation",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid remote gxserver event URL."]
      )
    }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.queryItems = [
      URLQueryItem(name: "protocolVersion", value: String(GxserverClient.protocolVersion)),
      URLQueryItem(name: "authToken", value: connection.token),
    ]
    guard let url = components.url else {
      throw NSError(
        domain: "RemoteGxserverPresentation",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Invalid remote gxserver event URL."]
      )
    }

    let task = URLSession.shared.webSocketTask(with: url)
    lock.lock()
    let previous = presentationSubscriptions[command.remoteMachineId]
    presentationSubscriptions[command.remoteMachineId] = task
    lock.unlock()
    previous?.cancel(with: .goingAway, reason: nil)

    task.resume()
    var subscribePayload: [String: Any] = [
      "clientId": command.clientId ?? "macos-remote-sidebar-\(command.remoteMachineId)",
      "type": "subscribePresentation",
    ]
    if let lastRevision = command.lastRevision {
      subscribePayload["lastRevision"] = lastRevision
    }
    let data = try JSONSerialization.data(withJSONObject: subscribePayload)
    let message = String(data: data, encoding: .utf8) ?? #"{"type":"subscribePresentation"}"#
    task.send(.string(message)) { [weak self] error in
      if let error {
        eventHandler(.remoteGxserverStatus(
          remoteMachineId: command.remoteMachineId,
          payloadJson: self?.statusPayloadJson([
            "message": error.localizedDescription,
            "ok": false,
            "requestId": command.requestId,
            "state": "presentationSubscribeFailed",
          ]) ?? #"{"ok":false,"state":"presentationSubscribeFailed"}"#
        ))
      }
    }
    receivePresentationMessages(remoteMachineId: command.remoteMachineId, task: task, eventHandler: eventHandler)
  }

  private func receivePresentationMessages(
    remoteMachineId: String,
    task: URLSessionWebSocketTask,
    eventHandler: @escaping (HostEvent) -> Void
  ) {
    task.receive { [weak self] result in
      guard let self else { return }
      self.lock.lock()
      let isCurrent = self.presentationSubscriptions[remoteMachineId] === task
      self.lock.unlock()
      guard isCurrent else { return }

      switch result {
      case .success(let message):
        let payloadJson: String?
        switch message {
        case .string(let text):
          payloadJson = text
        case .data(let data):
          payloadJson = String(data: data, encoding: .utf8)
        @unknown default:
          payloadJson = nil
        }
        if let payloadJson {
          eventHandler(.remoteGxserverPresentationEvent(
            remoteMachineId: remoteMachineId,
            payloadJson: payloadJson
          ))
        }
        self.receivePresentationMessages(remoteMachineId: remoteMachineId, task: task, eventHandler: eventHandler)
      case .failure(let error):
        eventHandler(.remoteGxserverStatus(
          remoteMachineId: remoteMachineId,
          payloadJson: self.statusPayloadJson([
            "message": error.localizedDescription,
            "ok": false,
            "state": "presentationStreamFailed",
          ])
        ))
      }
    }
  }

  private struct RemoteHealthProbeResult {
    let ok: Bool
    let lastStatusCode: Int?
    let lastErrorDescription: String?
  }

  private func waitForAuthenticatedHealth(baseURL: String, token: String) -> RemoteHealthProbeResult {
    let deadline = Date().addingTimeInterval(7)
    var lastStatusCode: Int?
    var lastErrorDescription: String?
    while Date() < deadline {
      do {
        let response = try performRequest(
          path: "/api/health/server",
          method: "GET",
          paramsJson: nil,
          baseURL: baseURL,
          token: token,
          timeoutSeconds: 1
        )
        lastStatusCode = response.statusCode
        if (200..<300).contains(response.statusCode) {
          return RemoteHealthProbeResult(ok: true, lastStatusCode: response.statusCode, lastErrorDescription: nil)
        }
      } catch {
        lastErrorDescription = (error as NSError).localizedDescription
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return RemoteHealthProbeResult(
      ok: false,
      lastStatusCode: lastStatusCode,
      lastErrorDescription: lastErrorDescription
    )
  }

  /*
   * CDXC:RemoteMachines 2026-06-13: Drain a finished process's pipe so the
   * tunnelFailed toast can carry the real ssh stderr / health detail. Only call
   * after the process has exited or been terminated, or availableData blocks.
   */
  private func drainPipeString(_ source: Any?, limit: Int = 400) -> String {
    guard let pipe = source as? Pipe else { return "" }
    let data = pipe.fileHandleForReading.availableData
    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
  }

  /*
   * CDXC:RemoteMachines 2026-06-13: tunnelFailed toasts truncate, hiding the
   * ssh argv / stderr / health detail needed to tell an ssh-forward failure
   * apart from a URLSession probe failure. Mirror the diagnostics to a dedicated
   * client-side log file so they survive regardless of toast length.
   */
  private func appendTunnelDebugLog(_ message: String) {
    let logsDirectory = GhostexAppStorage.logsDirectory
    let logURL = logsDirectory.appendingPathComponent("remote-gxserver-tunnel-debug.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    do {
      try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: logURL.path) {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
      } else {
        try line.write(to: logURL, atomically: true, encoding: .utf8)
      }
    } catch {
      // Best-effort diagnostics only.
    }
  }

  private func performRequest(_ command: RemoteGxserverRequest, connection: RemoteGxserverConnection) throws -> (statusCode: Int, body: String?) {
    try performRequest(
      path: command.path,
      method: command.method,
      paramsJson: command.paramsJson,
      baseURL: connection.baseURL,
      token: connection.token,
      timeoutSeconds: command.path == "/api/runBeadsAction" ? 60 : 15
    )
  }

  private func performRequest(
    path: String,
    method: String,
    paramsJson: String?,
    baseURL: String,
    token: String,
    timeoutSeconds: TimeInterval
  ) throws -> (statusCode: Int, body: String?) {
    guard path.hasPrefix("/api/") else {
      throw NSError(
        domain: "RemoteGxserverRequest",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid remote gxserver API path."])
    }
    guard let url = URL(string: "\(baseURL)\(path)") else {
      throw NSError(
        domain: "RemoteGxserverRequest",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Invalid remote gxserver API URL."])
    }
    var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
    request.httpMethod = method.uppercased()
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(String(GxserverClient.protocolVersion), forHTTPHeaderField: "x-gxserver-protocol-version")
    if request.httpMethod == "POST" {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let params = paramsJson?.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalizedParams = (params?.isEmpty == false) ? params! : "{}"
      request.httpBody = Data(#"{"protocolVersion":\#(GxserverClient.protocolVersion),"params":\#(normalizedParams)}"#.utf8)
    }
    return try sendSynchronousRequest(request)
  }

  private func sendSynchronousRequest(_ request: URLRequest) throws -> (statusCode: Int, body: String?) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(statusCode: Int, body: String?), Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
      defer { semaphore.signal() }
      if let error {
        result = .failure(error)
        return
      }
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      result = .success((statusCode, data.flatMap { String(data: $0, encoding: .utf8) }))
    }.resume()
    _ = semaphore.wait(timeout: .now() + request.timeoutInterval + 2)
    guard let result else {
      throw NSError(
        domain: "RemoteGxserverRequest",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Remote gxserver request timed out."])
    }
    return try result.get()
  }

  private func sshClientOptions(_ target: RemoteSshTarget) -> [String] {
    var arguments = [
      "-o", "UseKeychain=yes",
      "-o", "AddKeysToAgent=yes",
      "-o", "ConnectTimeout=8",
      "-o", "StrictHostKeyChecking=accept-new",
      /*
       * CDXC:RemoteMachines 2026-06-13: The presentation tunnel is a long-lived
       * `ssh -N -L`. Without keepalive, idle NAT/firewall timeouts or a
       * half-open TCP death silently drop it, surfacing as alternating
       * "sidebar stream failed" (WS receive error) and "could not reach
       * gxserver" (next health probe) toasts. Probe every 15s and tear the
       * connection down after 3 misses so the client detects the drop and
       * reconnects instead of flapping.
       */
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=3",
      "-o", "TCPKeepAlive=yes",
    ]
    if target.sshPasswordAccount?.isEmpty == false {
      /*
       CDXC:RemoteMachines 2026-06-09-18:23:
       Password-backed Remote machines cannot use SSH BatchMode because it
       suppresses password auth. Enable exactly one askpass prompt and let the
       helper read the saved credential from Keychain; key-only machines keep
       BatchMode so missing keys fail quickly without interactive prompts.
       */
      arguments.append(contentsOf: [
        "-o", "BatchMode=no",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "PreferredAuthentications=publickey,password,keyboard-interactive",
        "-o", "PasswordAuthentication=yes",
      ])
    } else {
      arguments.append(contentsOf: ["-o", "BatchMode=yes"])
    }
    return arguments
  }

  private func makeSshAskpassScript(target: RemoteSshTarget) throws -> RemoteSshAskpassScript? {
    guard let account = target.sshPasswordAccount, !account.isEmpty else {
      return nil
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostex-ssh-askpass-\(UUID().uuidString)", isDirectory: true)
    let script = directory.appendingPathComponent("askpass.sh")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let contents = """
    #!/bin/sh
    exec /usr/bin/security find-generic-password -s \(shellSingleQuoted(Self.sshPasswordKeychainService)) -a \(shellSingleQuoted(account)) -w
    """
    try contents.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return RemoteSshAskpassScript(directory: directory, script: script)
  }

  private func sshAskpassEnvironment(_ askpass: RemoteSshAskpassScript?) -> [String: String]? {
    guard let askpass else {
      return nil
    }
    var environment = ProcessInfo.processInfo.environment
    environment["DISPLAY"] = environment["DISPLAY"] ?? "localhost:0"
    environment["SSH_ASKPASS"] = askpass.script.path
    environment["SSH_ASKPASS_REQUIRE"] = "force"
    return environment
  }

  private func removeSshAskpassScript(_ askpass: RemoteSshAskpassScript?) {
    guard let askpass else {
      return
    }
    try? FileManager.default.removeItem(at: askpass.directory)
  }

  private func runSsh(target: RemoteSshTarget, remoteCommand: String, timeoutSeconds: TimeInterval) -> RemoteProcessResult {
    let askpass: RemoteSshAskpassScript?
    do {
      askpass = try makeSshAskpassScript(target: target)
    } catch {
      return RemoteProcessResult(exitCode: 126, stderr: "Could not prepare SSH password helper.", stdout: "")
    }
    defer {
      removeSshAskpassScript(askpass)
    }
    var arguments = sshClientOptions(target)
    arguments.append(contentsOf: sshTargetArguments(target))
    arguments.append(loginShellRemoteCommand(remoteCommand))
    return runProcess(
      executable: "/usr/bin/ssh",
      arguments: arguments,
      environment: sshAskpassEnvironment(askpass),
      timeoutSeconds: timeoutSeconds
    )
  }

  private func runScp(
    target: RemoteSshTarget,
    localPath: String,
    remotePath: String,
    timeoutSeconds: TimeInterval
  ) -> RemoteProcessResult {
    let askpass: RemoteSshAskpassScript?
    do {
      askpass = try makeSshAskpassScript(target: target)
    } catch {
      return RemoteProcessResult(exitCode: 126, stderr: "Could not prepare SSH password helper.", stdout: "")
    }
    defer {
      removeSshAskpassScript(askpass)
    }
    var arguments = sshClientOptions(target)
    if let identityFile = target.identityFile, !identityFile.isEmpty {
      arguments.append(contentsOf: ["-i", identityFile])
    }
    if let port = target.port, port > 0 {
      arguments.append(contentsOf: ["-P", String(port)])
    }
    arguments.append(localPath)
    arguments.append("\(remoteTargetHost(target)):\(remotePath)")
    return runProcess(
      executable: "/usr/bin/scp",
      arguments: arguments,
      environment: sshAskpassEnvironment(askpass),
      timeoutSeconds: timeoutSeconds
    )
  }

  private func runProcess(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    timeoutSeconds: TimeInterval
  ) -> RemoteProcessResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment {
      process.environment = environment
    }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      return RemoteProcessResult(exitCode: 127, stderr: error.localizedDescription, stdout: "")
    }

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      return RemoteProcessResult(exitCode: 124, stderr: "Remote SSH command timed out.", stdout: "")
    }
    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return RemoteProcessResult(exitCode: process.terminationStatus, stderr: stderr, stdout: stdout)
  }

  private func sshTargetArguments(_ target: RemoteSshTarget) -> [String] {
    var args: [String] = []
    if let identityFile = target.identityFile, !identityFile.isEmpty {
      args.append(contentsOf: ["-i", identityFile])
    }
    if let port = target.port, port > 0 {
      args.append(contentsOf: ["-p", String(port)])
    }
    let host = target.user?.isEmpty == false ? "\(target.user!)@\(target.host)" : target.host
    args.append(host)
    return args
  }

  private func expandedLocalPath(_ path: String?) -> String? {
    let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    return (trimmed as NSString).expandingTildeInPath
  }

  private func loginShellRemoteCommand(_ command: String) -> String {
    /*
     CDXC:RemoteMachines 2026-06-08-19:12:
     Remote macOS hosts can have Ghostex, gxserver, and Node installed through
     Homebrew or mise in user shell startup files. Native SSH setup must execute
     daemon checks through the user's zsh login+interactive environment and
     still resolve the app-installed ~/.ghostex package path, otherwise a
     running `ghostex server` appears missing from non-interactive SSH.
     */
    let quotedCommand = shellSingleQuoted(command)
    return """
    if [ -x /bin/zsh ]; then exec /bin/zsh -lic \(quotedCommand); \
    elif command -v zsh >/dev/null 2>&1; then exec zsh -lic \(quotedCommand); \
    else exec /bin/sh -lc \(quotedCommand); fi
    """
  }

  private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func remoteTargetHost(_ target: RemoteSshTarget) -> String {
    target.user?.isEmpty == false ? "\(target.user!)@\(target.host)" : target.host
  }

  private func connection(for remoteMachineId: String) throws -> RemoteGxserverConnection {
    lock.lock()
    let connection = connections[remoteMachineId]
    lock.unlock()
    guard let connection, connection.tunnelProcess.isRunning else {
      throw NSError(
        domain: "RemoteGxserverConnection",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Remote gxserver is not connected."])
    }
    return connection
  }

  private func terminateExistingConnection(remoteMachineId: String) {
    lock.lock()
    let existing = connections.removeValue(forKey: remoteMachineId)
    let subscription = presentationSubscriptions.removeValue(forKey: remoteMachineId)
    lock.unlock()
    subscription?.cancel(with: .goingAway, reason: nil)
    if existing?.tunnelProcess.isRunning == true {
      existing?.tunnelProcess.terminate()
    }
  }

  private func storeTokenInKeychain(_ token: String, remoteMachineId: String) throws {
    guard let tokenData = token.data(using: .utf8) else {
      throw NSError(domain: "RemoteGxserverKeychain", code: 1)
    }
    let query: [String: Any] = [
      kSecAttrAccount as String: remoteMachineId,
      kSecAttrService as String: Self.keychainService,
      kSecClass as String: kSecClassGenericPassword,
      /*
       * CDXC:RemoteMachines 2026-06-13: Target the file/login keychain
       * explicitly. Ad-hoc-signed dev builds have no keychain-access-groups
       * entitlement, so SecItemAdd into the data-protection keychain returns
       * errSecMissingEntitlement (-34018). The login keychain needs no
       * entitlement and matches the `security` CLI used by the SSH askpass.
       */
      kSecUseDataProtectionKeychain as String: false,
    ]
    SecItemDelete(query as CFDictionary)
    var addQuery = query
    addQuery[kSecValueData as String] = tokenData
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: "RemoteGxserverKeychain", code: Int(status))
    }
  }

  private func storeSshPasswordInKeychain(_ password: String, remoteMachineId: String) throws {
    guard let passwordData = password.data(using: .utf8) else {
      throw NSError(domain: "RemoteSshPasswordKeychain", code: 1)
    }
    let query = sshPasswordKeychainQuery(remoteMachineId: remoteMachineId)
    SecItemDelete(query as CFDictionary)
    var addQuery = query
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    addQuery[kSecValueData as String] = passwordData
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: "RemoteSshPasswordKeychain", code: Int(status))
    }
  }

  private func deleteSshPasswordFromKeychain(remoteMachineId: String) throws {
    let status = SecItemDelete(sshPasswordKeychainQuery(remoteMachineId: remoteMachineId) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: "RemoteSshPasswordKeychain", code: Int(status))
    }
  }

  private func keychainHasSshPassword(remoteMachineId: String) -> Bool {
    var query = sshPasswordKeychainQuery(remoteMachineId: remoteMachineId)
    query[kSecReturnData as String] = false
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  private func sshPasswordKeychainQuery(remoteMachineId: String) -> [String: Any] {
    [
      kSecAttrAccount as String: remoteMachineId,
      kSecAttrService as String: Self.sshPasswordKeychainService,
      kSecClass as String: kSecClassGenericPassword,
      /*
       * CDXC:RemoteMachines 2026-06-13: Use the file/login keychain so the SSH
       * askpass helper (which reads via `security find-generic-password`) can
       * find the saved password, and so ad-hoc dev builds avoid the
       * data-protection keychain's entitlement requirement (-34018).
       */
      kSecUseDataProtectionKeychain as String: false,
    ]
  }

  private func statusEvent(
    _ command: RemoteGxserverConnect,
    state: String,
    ok: Bool,
    message: String,
    extra: [String: Any] = [:]
  ) -> HostEvent {
    var payload: [String: Any] = [
      "message": message,
      "ok": ok,
      "protocolVersion": GxserverClient.protocolVersion,
      "requestId": command.requestId,
      "state": state,
    ]
    for (key, value) in extra {
      payload[key] = value
    }
    return .remoteGxserverStatus(
      remoteMachineId: command.remoteMachineId,
      payloadJson: statusPayloadJson(payload)
    )
  }

  private func statusPayloadJson(_ payload: [String: Any]) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let payloadJson = String(data: data, encoding: .utf8)
    else {
      return #"{"ok":false,"state":"invalid","message":"Could not encode remote gxserver status."}"#
    }
    return payloadJson
  }

  private func isValidAuthToken(_ token: String) -> Bool {
    token.range(of: #"^[A-Za-z0-9_-]{32,}$"#, options: .regularExpression) != nil
  }

  private func extractRemoteAuthToken(from stdout: String) -> String {
    if
      let start = stdout.range(of: "__GHOSTEX_REMOTE_TOKEN_START__"),
      let end = stdout.range(of: "__GHOSTEX_REMOTE_TOKEN_END__", range: start.upperBound..<stdout.endIndex)
    {
      return String(stdout[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let matchRange = stdout.range(of: #"[A-Za-z0-9_-]{32,}"#, options: .regularExpression)
    return matchRange.map { String(stdout[$0]) } ?? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func sanitizedProcessFailure(defaultMessage: String, result: RemoteProcessResult) -> String {
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if stderr.isEmpty {
      return defaultMessage
    }
    if stderr.localizedCaseInsensitiveContains("permission denied") {
      return "SSH authentication failed for the remote machine."
    }
    if stderr.localizedCaseInsensitiveContains("could not resolve hostname") {
      return "SSH could not resolve the remote host."
    }
    if stderr.localizedCaseInsensitiveContains("operation timed out") ||
      stderr.localizedCaseInsensitiveContains("connection timed out") {
      return "SSH connection to the remote machine timed out."
    }
    return defaultMessage
  }
}

private struct RemoteSshTarget {
  let host: String
  let identityFile: String?
  let port: Int?
  let sshPasswordAccount: String?
  let user: String?
}
