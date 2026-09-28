import Foundation
import simd

struct DeskTracker {
    private let standardGravity = 9.81
    private let flatGravity = 0.97
    private let liftTiltRate = 0.2
    private let liftAcceleration = 0.06
    private let calmTiltRate = 0.05
    private let calmAcceleration = 0.02
    private let calmSamples = 30
    private let steadySpread = 0.004
    private let meanRate = 0.2
    private let quietAcceleration = 0.006
    private let quietTurnRate = 0.03
    private let quietSamples = 5
    private let landingSamples = 8
    private let leadTime = 0.02
    private let biasRate = 0.02
    private let maxStrokeDuration = 6.0
    private let forgiveWindow = 0.15

    private var lifted = true
    private var liftedAt = 0.0
    private var lastTime = 0.0
    private var mean: SIMD2<Double>?
    private var bias = SIMD2<Double>.zero
    private var velocity = SIMD2<Double>.zero
    private var heading = 0.0
    private var strokeDuration = 0.0
    private var calmCount = 0
    private var steadyCount = 0
    private var quietCount = 0

    mutating func reset() {
        velocity = .zero
        heading = 0
        strokeDuration = 0
    }

    mutating func forgiveLift() {
        if lifted, lastTime - liftedAt < forgiveWindow {
            lifted = false
        }
    }

    mutating func displacement(
        acceleration raw: SIMD2<Double>,
        vertical: Double,
        rotation: SIMD3<Double>,
        gravityZ: Double,
        time: TimeInterval,
        dt: Double
    ) -> SIMD2<Double> {
        lastTime = time
        var average = mean ?? raw
        average += (raw - average) * meanRate
        mean = average

        let tiltRate = hypot(rotation.x, rotation.y)
        let flat = abs(gravityZ) > flatGravity
        let calm = flat && tiltRate < calmTiltRate && abs(vertical) < calmAcceleration
        calmCount = calm ? calmCount + 1 : 0
        let steady = simd_length(raw - average) < steadySpread && abs(rotation.z) < quietTurnRate
        steadyCount = steady ? steadyCount + 1 : 0

        if !flat || tiltRate > liftTiltRate || abs(vertical) > liftAcceleration {
            if !lifted {
                liftedAt = time
            }
            lifted = true
        }
        if lifted {
            guard calmCount >= calmSamples, steadyCount >= landingSamples else {
                reset()
                quietCount = 0
                return .zero
            }
            lifted = false
            bias = average
            quietCount = quietSamples
        }

        let acceleration = raw - bias
        let quiet = simd_length(acceleration) < quietAcceleration && abs(rotation.z) < quietTurnRate
        quietCount = quiet ? quietCount + 1 : 0
        if quietCount >= quietSamples {
            reset()
            bias += (raw - bias) * biasRate
            return .zero
        }
        strokeDuration += dt
        guard strokeDuration < maxStrokeDuration else {
            velocity = .zero
            return .zero
        }
        heading += rotation.z * dt
        let c = cos(heading)
        let s = sin(heading)
        let world = SIMD2(c * acceleration.x - s * acceleration.y, s * acceleration.x + c * acceleration.y)
        velocity += world * standardGravity * dt
        let ahead = velocity + world * standardGravity * leadTime
        return SIMD2(c * ahead.x + s * ahead.y, -s * ahead.x + c * ahead.y) * dt
    }
}
