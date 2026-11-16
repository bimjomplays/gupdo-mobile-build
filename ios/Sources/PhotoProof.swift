import AVFoundation
import SwiftUI
import UIKit
import Vision

// Photo proof: the reference photo of the habit's spot is taken with the live camera at setup; proof is another live
// camera photo, compared with it on the phone (Vision image feature prints, no network). There is no way in from the
// photo library: the only camera is `LiveCamera` below, and only its shutter produces a proof photo.

/// The habit photos, in the app's own folder (never the photo library), readable after the first unlock.
struct PhotoStore {
    var folder: URL

    static let app = PhotoStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("photos", isDirectory: true))

    /// Longest side of a stored photo (enough for the feature print and for showing it).
    static let maxSide: CGFloat = 1024

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    func load(_ name: String?) -> UIImage? {
        guard let name, !name.isEmpty else { return nil }
        return UIImage(contentsOfFile: url(name).path)
    }

    /// Saves `image` (upright, scaled down) as `name`.
    @discardableResult
    func save(_ image: UIImage, as name: String) -> Bool {
        guard let data = Self.prepared(image).jpegData(compressionQuality: 0.85) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    func delete(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(name))
    }

    /// Upright (orientation applied) and at most `maxSide` on its longest side.
    static func prepared(_ image: UIImage) -> UIImage {
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// On-device scene comparison with Vision's image feature prints.
enum PhotoMatcher {
    enum Failure: Error { case noImage, emptyFeaturePrint }

    /// Throws rather than return an empty feature print (the iOS Simulator gives all zeros, which would make every
    /// photo "match"): a matcher that can't see never proves anything.
    static func featurePrint(_ image: UIImage) async throws -> FeaturePrintObservation {
        guard let cg = PhotoStore.prepared(image).cgImage else { throw Failure.noImage }
        let print = try await GenerateImageFeaturePrintRequest().perform(on: cg, orientation: .up)
        guard print.data.contains(where: { $0 != 0 }) else { throw Failure.emptyFeaturePrint }
        return print
    }

    /// Feature-print distance between two photos: small = the same scene (see `PhotoMatch.threshold`).
    static func distance(_ a: UIImage, _ b: UIImage) async throws -> Double {
        let fa = try await featurePrint(a)
        let fb = try await featurePrint(b)
        return try fa.distance(to: fb)
    }
}

// MARK: - Live camera

/// A full-screen live camera. With a reference photo it lies over the preview, see-through, so the new photo can be
/// lined up with the spot. The shutter is the only way a photo leaves it.
struct LiveCamera: View {
    var title: String
    var reference: UIImage?
    var onPhoto: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var camera = CameraController()
    @State private var overlay = true
    @State private var denied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.available {
                CameraPreview(session: camera.session).ignoresSafeArea()
                if let reference, overlay {
                    GeometryReader { geo in
                        Image(uiImage: reference)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .opacity(0.35)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            } else {
                ContentUnavailableView(denied ? "Camera not allowed" : "No camera",
                                       systemImage: "camera.fill",
                                       description: Text(denied ? "Allow the camera for GupDo in Settings to take the photo."
                                                         : "This device has no camera."))
                    .foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Button("Cancel", action: onCancel).foregroundStyle(.white)
                    Spacer()
                    if reference != nil, camera.available {
                        Toggle("Line up", isOn: $overlay).toggleStyle(.button).tint(.white)
                    }
                }
                .padding()
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                Spacer()
                Button {
                    camera.capture { image in if let image { onPhoto(image) } }
                } label: {
                    Circle().strokeBorder(.white, lineWidth: 4)
                        .background(Circle().fill(.white.opacity(camera.busy ? 0.3 : 0.9)).padding(6))
                        .frame(width: 76, height: 76)
                }
                .disabled(!camera.available || camera.busy)
                .accessibilityLabel("Take photo")
                .accessibilityIdentifier("camera-shutter")
                .padding(.bottom, 30)
            }
        }
        .task {
            denied = !(await camera.start())
        }
        .onDisappear { camera.stop() }
    }
}

@Observable
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private var done: ((UIImage?) -> Void)?
    @ObservationIgnored private let queue = DispatchQueue(label: "gupdo.camera")
    private(set) var available = false
    private(set) var busy = false

    /// Sets up the back camera; false when camera access is denied.
    @MainActor
    func start() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return false }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return true }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let session = self.session
        queue.async { session.startRunning() }
        available = true
        return true
    }

    func stop() {
        let session = self.session
        queue.async { session.stopRunning() }
    }

    @MainActor
    func capture(_ done: @escaping (UIImage?) -> Void) {
        guard available, !busy else { return }
        busy = true
        self.done = done
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90  // portrait
        }
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        Task { @MainActor in
            self.busy = false
            self.done?(image)
            self.done = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
