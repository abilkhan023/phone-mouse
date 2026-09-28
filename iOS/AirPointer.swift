import Foundation
import simd

struct AirPointer {
    private let slowGain = 1500.0
    private let fastGain = 4000.0
    private let slowSpeed = 0.2
    private let fastSpeed = 2.0
    private let tightSpeed = 0.05
    private let smoothFrom = 0.09
    private let smoothTo = 0.18
    private let smoothSamples = 10
    private let minLateral = 0.2
    private let rewindSamples = 8

    private var smoothing: [SIMD2<Double>] = []
    private var smoothingIndex = 0
    private var recent: [SIMD2<Double>] = []
    private var recentIndex = 0

    mutating func reset() {
        smoothing.removeAll()
        smoothingIndex = 0
        recent.removeAll()
        recentIndex = 0
    }

    mutating func rewind() -> SIMD2<Double> {
        let undo = recent.reduce(SIMD2<Double>.zero, +)
        recent.removeAll()
        recentIndex = 0
        return -undo
    }

    mutating func movement(rotation: SIMD3<Double>, gravity: SIMD3<Double>, dt: Double) -> SIMD2<Double> {
        guard simd_length(gravity) > 0.5 else { return .zero }
        let up = -simd_normalize(gravity)
        let side = SIMD3<Double>(1, 0, 0)
        let lateral = side - simd_dot(side, up) * up
        let length = simd_length(lateral)
        let yaw = simd_dot(rotation, up)
        let pitch = length > minLateral ? simd_dot(rotation, lateral / length) : 0

        var turn = SIMD2(yaw, pitch)
        let speed = simd_length(turn)
        if speed < tightSpeed {
            turn *= speed / tightSpeed
        }
        let direct = min(max((speed - smoothFrom) / (smoothTo - smoothFrom), 0), 1)
        let blended = turn * direct + average(adding: turn * (1 - direct))
        let boost = min(max((speed - slowSpeed) / (fastSpeed - slowSpeed), 0), 1)
        let gain = slowGain + (fastGain - slowGain) * boost
        let step = SIMD2(-blended.x, -blended.y) * gain * dt
        remember(step)
        return step
    }

    private mutating func average(adding value: SIMD2<Double>) -> SIMD2<Double> {
        if smoothing.count < smoothSamples {
            smoothing.append(value)
        } else {
            smoothing[smoothingIndex] = value
            smoothingIndex = (smoothingIndex + 1) % smoothSamples
        }
        return smoothing.reduce(SIMD2<Double>.zero, +) / Double(smoothing.count)
    }

    private mutating func remember(_ step: SIMD2<Double>) {
        if recent.count < rewindSamples {
            recent.append(step)
        } else {
            recent[recentIndex] = step
            recentIndex = (recentIndex + 1) % rewindSamples
        }
    }
}
