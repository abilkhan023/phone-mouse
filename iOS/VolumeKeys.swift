import AVFoundation
import MediaPlayer
import SwiftUI

// iOS has no API for the volume buttons, so they are read from changes of the
// system volume. After each press the volume is put back, which keeps the
// phone's own level where it was, and a hidden MPVolumeView keeps the system
// volume overlay from showing.
final class VolumeKeys {
    var onPress: ((VolumeEvent.Direction) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let step: Float = 1 / 16
    private let tolerance: Float = 0.001

    private var observation: NSKeyValueObservation?
    private var slider: UISlider?
    private var anchor: Float = 0.5
    private var original: Float?

    func attach(_ slider: UISlider) {
        self.slider = slider
        if observation != nil, abs(session.outputVolume - anchor) > tolerance {
            setVolume(anchor)
        }
    }

    func start() {
        guard observation == nil else { return }
        try? session.setCategory(.ambient, options: .mixWithOthers)
        try? session.setActive(true)
        let volume = session.outputVolume
        original = volume
        anchor = min(max(volume, step), 1 - step)
        if abs(anchor - volume) > tolerance {
            setVolume(anchor)
        }
        observation = session.observe(\.outputVolume, options: .new) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            DispatchQueue.main.async { self?.volumeChanged(to: volume) }
        }
    }

    func stop() {
        guard observation != nil else { return }
        observation = nil
        if let original, abs(original - session.outputVolume) > tolerance {
            setVolume(original)
        }
        original = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func volumeChanged(to volume: Float) {
        guard observation != nil, abs(volume - anchor) > tolerance else { return }
        onPress?(volume > anchor ? .up : .down)
        setVolume(anchor)
    }

    private func setVolume(_ value: Float) {
        guard let slider else { return }
        DispatchQueue.main.async {
            slider.value = value
            slider.sendActions(for: .valueChanged)
        }
    }
}

struct VolumeKeysView: UIViewRepresentable {
    let keys: VolumeKeys

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            keys.attach(slider)
        }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
