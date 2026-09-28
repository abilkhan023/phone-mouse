import AVFoundation
import SwiftUI
import UIKit

struct PairingScanner: UIViewRepresentable {
    let onScan: (Pairing) -> Void

    func makeUIView(context: Context) -> ScannerView {
        let view = ScannerView()
        view.onScan = onScan
        return view
    }

    func updateUIView(_ view: ScannerView, context: Context) {
        view.onScan = onScan
    }

    static func dismantleUIView(_ view: ScannerView, coordinator: ()) {
        view.stop()
    }
}

final class ScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((Pairing) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "PairingScanner")
    private var didScan = false

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            self?.queue.async { self?.configure() }
        }
    }

    required init?(coder: NSCoder) { nil }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.startRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didScan else { return }
        for case let code as AVMetadataMachineReadableCodeObject in objects {
            guard let text = code.stringValue, let pairing = Pairing(code: text) else { continue }
            didScan = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            stop()
            onScan?(pairing)
            return
        }
    }
}
