import Foundation
import LabRouteCore

@MainActor extension ApplicationController {
    public func answerCredential(_ value: String?) {
        credential = nil; credentialValue = ""; humanInteraction = nil
        let continuation = credentialContinuation
        credentialContinuation = nil
        continuation?.resume(returning: value)
    }

    public func cancelSetup() {
        cancellationRequested = true
        guard !proxyTransactionInProgress else { return }
        setupTask?.cancel()
        answerCredential(nil)
    }

    public func setup() {
        guard ownsRuntime, !serving, !needsRecovery else { error = "Disconnect and resolve recovery before SSH setup."; return }
        guard environment.onboardingAllowed else { error = "Credential onboarding is disabled in fixtures."; return }
        guard !busy, !shutdownRequested, var saved = configuration else { return }
        busy = true; error = nil
        var operation = ControlOperation(command: "setup")
        operation.phase = .running; operations.append(operation)
        if operations.count > 100 { operations.removeFirst() }
        activeOperation = operation.id; cancellationRequested = false
        setupTask = Task { [self] in
            var outcome: Result<Void, ControlFailure> = .success(())
            defer { busy = false; setupTask = nil; answerCredential(nil); finishOperation(outcome) }
            do {
                guard let port = UInt16(sshPort), port > 0 else { throw ConnectionError.invalid }
                let connection = Connection(id: setupID, institution: institution, hostname: hostname,
                    port: port, username: username, keyReference: keyPath.isEmpty ? nil : keyPath)
                let helper = environment.helper
                let verified = try await environment.onboarding.setup(connection, helper: helper) { [weak self] question in
                    guard let self, !Task.isCancelled else { return nil }
                    if let prompt = self.prompt {
                        self.humanInteraction = "credential"
                        defer { self.humanInteraction = nil }
                        return await prompt(question)
                    }
                    return await withCheckedContinuation { continuation in
                        self.humanInteraction = "credential"
                        self.credentialContinuation = continuation
                        self.credentialValue = ""
                        self.credential = question
                    }
                }
                try Task.checkCancellation()
                saved.connection = verified
                saved.selectedServiceIDs = selectedServices.sorted()
                saved.networkLocationID = services.first { selectedServices.contains($0.id) }?.locationID
                try store.save(saved)
                configuration = saved; configuredConnection = verified
                keyPath = verified.keyReference ?? ""
                status = "SSH key verified · ready to connect"
            } catch is CancellationError { outcome = .failure(ControlFailure(code: .cancelled)); status = "Setup cancelled" }
            catch { outcome = operationFailure(error); self.error = error.localizedDescription }
        }
    }

}
