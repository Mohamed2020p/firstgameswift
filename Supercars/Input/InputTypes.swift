import Foundation
import CoreGraphics
import Combine

// MARK: - Public input types (see docs/ARCHITECTURE.md).
//
// Conventions of the values delivered in `InputState` (documented for the other modules):
//   steer      -1 ... 1, POSITIVE = turn LEFT (same as the vehicle physics convention)
//   throttle / brake  0 ... 1
//   moveX      -1 ... 1, POSITIVE = strafe RIGHT (screen right)
//   moveY      -1 ... 1, POSITIVE = FORWARD (screen up on the joystick)
//   lookDX     radians for THIS frame, already multiplied by the camera sensitivity. POSITIVE = finger / stick moved RIGHT
//   lookDY     radians for THIS frame, POSITIVE = finger / stick moved DOWN (flipped when `invertLookY` is on)
//   run, handbrake, horn are LEVELS; jump, interact, cameraToggle, pause, lights, shiftUp, shiftDown are one-frame EDGES.

struct InputState {
    var steer: Float = 0
    var throttle: Float = 0
    var brake: Float = 0
    var handbrake: Bool = false
    var shiftUp: Bool = false
    var shiftDown: Bool = false
    var moveX: Float = 0
    var moveY: Float = 0
    var run: Bool = false
    var jump: Bool = false
    var lookDX: Float = 0
    var lookDY: Float = 0
    var interact: Bool = false
    var cameraToggle: Bool = false
    var pause: Bool = false
    var map: Bool = false
    var horn: Bool = false
    var lights: Bool = false
}

enum InputContext {
    case menu, onFoot, driving
}

enum HapticKind {
    case light, medium, heavy, rigid, soft, success, warning, error
}

// MARK: - Touch plumbing

/// Every on-screen control has one zone kind. The SwiftUI views only DRAW the controls; a single UIKit surface tracks the fingers.
enum TouchZoneKind: Hashable {
    case wheel, leftButton, rightButton, gas, brake, handbrake
    case shiftUp, shiftDown, camera, lights, horn, interact, pause
    case jump, run, calibrate, prompt, map
    case joystick, look
}

struct TouchZone: Equatable, Identifiable {
    var kind: TouchZoneKind
    var rect: CGRect
    var isCircle: Bool
    var id: TouchZoneKind { return kind }

    func contains(_ p: CGPoint) -> Bool {
        if isCircle {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = max(rect.width, rect.height) * 0.5
            let dx = p.x - c.x
            let dy = p.y - c.y
            return (dx * dx + dy * dy) <= r * r
        }
        return rect.contains(p)
    }
}

/// Plain fields written by the UIKit touch surface and consumed by `InputManager.update`. NOT published on purpose (60 Hz writes).
final class TouchInput: ObservableObject {
    /// steering wheel widget, -1 ... 1, POSITIVE = left. Spring return is applied by InputManager when the finger lifts.
    var steerWheel: Float = 0
    var wheelActive: Bool = false
    var leftDown: Bool = false
    var rightDown: Bool = false
    var gas: Float = 0                // 0 or 1 while a finger is on the pedal
    var brake: Float = 0
    var handbrake: Bool = false
    /// virtual joystick, -1 ... 1  (x right, y forward/up)
    var moveX: Float = 0
    var moveY: Float = 0
    /// accumulated look drag in screen points since the last frame (consumed by InputManager)
    var lookDX: Float = 0
    var lookDY: Float = 0
    var runHeld: Bool = false          // toggled by the run button
    var hornHeld: Bool = false
    // one-shot taps (set by the surface, cleared by InputManager after it copied them into the frame's edge flags)
    var interactTap: Bool = false
    var cameraTap: Bool = false
    var shiftUpTap: Bool = false
    var shiftDownTap: Bool = false
    var lightsTap: Bool = false
    var pauseTap: Bool = false
    var mapTap: Bool = false
    var jumpTap: Bool = false
    var calibrateTap: Bool = false

    func clearAll() {
        steerWheel = 0
        wheelActive = false
        leftDown = false
        rightDown = false
        gas = 0
        brake = 0
        handbrake = false
        moveX = 0
        moveY = 0
        lookDX = 0
        lookDY = 0
        hornHeld = false
        interactTap = false
        cameraTap = false
        shiftUpTap = false
        shiftDownTap = false
        lightsTap = false
        pauseTap = false
        mapTap = false
        jumpTap = false
        calibrateTap = false
    }
}

/// Event-driven look of the touch controls (pressed states, floating joystick). Changes only when a finger goes down / up / moves the stick.
final class TouchVisuals: ObservableObject {
    @Published var pressed: Set<TouchZoneKind> = []
    @Published var joystickActive: Bool = false
    @Published var joystickBase: CGPoint = CGPoint.zero
    @Published var joystickKnob: CGPoint = CGPoint.zero
    @Published var runLatched: Bool = false
    @Published var padConnected: Bool = false
    @Published var motionAvailable: Bool = false
}

/// Per-frame steering values for the wheel widget, the tilt indicator and the live tilt preview in Settings.
final class SteerVisuals: ObservableObject {
    @Published var wheel: Float = 0            // raw wheel widget value, +1 = full lock left
    @Published var steer: Float = 0            // final steering sent to the car
    @Published var tilt: Float = 0             // processed tilt steering (always computed while motion runs)
    @Published var tiltRollDegrees: Float = 0  // roll relative to the calibrated neutral, degrees (clockwise +)
}
