import CoreNFC
import Foundation

/// Reads an NFC tag's UID (Core NFC tag reader session): the habit's tag is registered at setup by scanning it, and
/// scanning the same tag proves the habit. Any common sticker works (NTAG / MIFARE, ISO 7816, ISO 15693); nothing is
/// written to it.
final class TagScanner: NSObject, NFCTagReaderSessionDelegate {
    enum Failure: Error, Equatable {
        case unavailable
        case cancelled
        case unreadable(String)
    }

    static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<String, Error>?

    /// Shows the system scan sheet with `prompt` and returns the tag's id (`NFCTagID.string`).
    @MainActor
    func scan(prompt: String) async throws -> String {
        guard Self.isAvailable else { throw Failure.unavailable }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            guard let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self,
                                                    queue: nil) else {
                finish(.failure(Failure.unavailable))
                return
            }
            session.alertMessage = prompt
            self.session = session
            session.begin()
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        session = nil
        c.resume(with: result)
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let code = (error as? NFCReaderError)?.code
        if code == .readerSessionInvalidationErrorUserCanceled || code == .readerSessionInvalidationErrorSessionTimeout {
            finish(.failure(Failure.cancelled))
        } else {
            finish(.failure(Failure.unreadable(error.localizedDescription)))
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { [weak self] error in
            if let error {
                session.invalidate(errorMessage: "Couldn't read that tag. Try again.")
                self?.finish(.failure(Failure.unreadable(error.localizedDescription)))
                return
            }
            let bytes: Data
            switch tag {
            case .miFare(let t): bytes = t.identifier
            case .iso7816(let t): bytes = t.identifier
            case .iso15693(let t): bytes = t.identifier
            case .feliCa(let t): bytes = t.currentIDm
            @unknown default: bytes = Data()
            }
            guard !bytes.isEmpty else {
                session.invalidate(errorMessage: "That tag has no id GupDo can use.")
                self?.finish(.failure(Failure.unreadable("no id")))
                return
            }
            session.alertMessage = "Got it"
            session.invalidate()
            self?.finish(.success(NFCTagID.string([UInt8](bytes))))
        }
    }
}
