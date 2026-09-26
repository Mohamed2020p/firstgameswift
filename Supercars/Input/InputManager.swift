import Foundation
import UIKit
import CoreMotion
import GameController
import Combine

// MARK: - InputManager: merges tilt steering, on-screen touch controls, game controllers and a hardware keyboard into `InputState`.

private func inputMoveToward(_ current: Float, _ target: Float, _ maxDelta: Float) -> Float {
    if current < target { return min(current + maxDelta, target) }
    if current > target { return max(current - maxDelta, target) }
    return current
}

private func inputDeadzone(_ v: Float, _ dz: Float) -> Float {
    let a: Float = abs(v)
    if a <= dz { return 0 }
    let scaled: Float = (a - dz) / (1 - dz)
    return v < 0 ? -scaled : scaled
}

@MainActor
final class InputManager: ObservableObject {

    private unowned let ctx: GameContext

    /// The merged input of the current frame (edge flags are true for exactly one frame).
    private(set) var state: InputState = InputState()

    var context: InputContext = InputContext.menu {
        didSet {
            if context != oldValue { contextDidChange(from: oldValue) }
        }
    }

    /// written by the touch surface / SwiftUI touch controls
    let touch: TouchInput = TouchInput()
    let visuals: TouchVisuals = TouchVisuals()
    let steerVisuals: SteerVisuals = SteerVisuals()

    // MARK: Tilt
    private let motion: CMMotionManager = CMMotionManager()
    private var motionRunning: Bool = false
    private var tiltHaveSample: Bool = false
    private var tiltRaw: Float = 0            // last valid roll, radians, clockwise positive
    private var tiltNeutral: Float = 0
    private var tiltCalibrated: Bool = false
    private var tiltFiltered: Float = 0       // processed steering, + = left
    private var autoCalibrateTimer: Float = 0.8

    // MARK: Smoothed touch values
    private var buttonSteer: Float = 0
    private var keySteer: Float = 0
    private var touchGas: Float = 0
    private var touchBrake: Float = 0

    // MARK: Edge detection for pads / keyboard
    private var previousDown: [String: Bool] = [:]

    // MARK: Haptics
    private let impactLight: UIImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium: UIImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy: UIImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let impactRigid: UIImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let impactSoft: UIImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let notifier: UINotificationFeedbackGenerator = UINotificationFeedbackGenerator()

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    init(ctx: GameContext) {
        self.ctx = ctx
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        impactRigid.prepare()
        impactSoft.prepare()
        notifier.prepare()
        registerControllerObservers()
        visuals.padConnected = !GCController.controllers().isEmpty
    }

    // MARK: - Public API

    var tiltAvailable: Bool { return motion.isDeviceMotionAvailable }

    func startMotion() {
        if motionRunning { return }
        guard motion.isDeviceMotionAvailable else {
            visuals.motionAvailable = false
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates()
        motionRunning = true
        visuals.motionAvailable = true
    }

    func stopMotion() {
        if !motionRunning { return }
        motion.stopDeviceMotionUpdates()
        motionRunning = false
    }

    /// Makes the current phone pose the "straight ahead" wheel position.
    func calibrateTilt() {
        if tiltHaveSample { tiltNeutral = tiltRaw }
        tiltCalibrated = true
        tiltFiltered = 0
        autoCalibrateTimer = 0
    }

    func haptic(_ kind: HapticKind) {
        if !ctx.settings.settings.controls.haptics { return }
        switch kind {
        case .light:
            impactLight.impactOccurred()
            impactLight.prepare()
        case .medium:
            impactMedium.impactOccurred()
            impactMedium.prepare()
        case .heavy:
            impactHeavy.impactOccurred()
            impactHeavy.prepare()
        case .rigid:
            impactRigid.impactOccurred()
            impactRigid.prepare()
        case .soft:
            impactSoft.impactOccurred()
            impactSoft.prepare()
        case .success:
            notifier.notificationOccurred(.success)
            notifier.prepare()
        case .warning:
            notifier.notificationOccurred(.warning)
            notifier.prepare()
        case .error:
            notifier.notificationOccurred(.error)
            notifier.prepare()
        }
    }

    // MARK: - Frame update

    func update(dt: Float) {
        let c: ControlSettings = ctx.settings.settings.controls
        updateTilt(dt: dt, controls: c)

        let pad: GCExtendedGamepad? = activePad()
        let kb: GCKeyboardInput? = GCKeyboard.coalesced?.keyboardInput

        // wheel widget spring return when the finger is lifted
        if !touch.wheelActive && touch.steerWheel != 0 {
            let back: Float = damp(touch.steerWheel, 0, 9, dt)
            touch.steerWheel = abs(back) < 0.004 ? 0 : back
        }

        // consume one-shot touch taps
        let tapInteract: Bool = touch.interactTap
        let tapCamera: Bool = touch.cameraTap
        let tapShiftUp: Bool = touch.shiftUpTap
        let tapShiftDown: Bool = touch.shiftDownTap
        let tapLights: Bool = touch.lightsTap
        let tapPause: Bool = touch.pauseTap
        let tapMap: Bool = touch.mapTap
        let tapJump: Bool = touch.jumpTap
        let tapCalibrate: Bool = touch.calibrateTap
        touch.interactTap = false
        touch.cameraTap = false
        touch.shiftUpTap = false
        touch.shiftDownTap = false
        touch.lightsTap = false
        touch.pauseTap = false
        touch.mapTap = false
        touch.jumpTap = false
        touch.calibrateTap = false
        if tapCalibrate {
            calibrateTilt()
            haptic(.medium)
            ctx.toast("Tilt calibrated")
        }

        var s: InputState = InputState()

        // buttons that exist on every device
        let padA: Bool = pad?.buttonA.isPressed ?? false
        let padB: Bool = pad?.buttonB.isPressed ?? false
        let padX: Bool = pad?.buttonX.isPressed ?? false
        let padY: Bool = pad?.buttonY.isPressed ?? false
        let padLS: Bool = pad?.leftShoulder.isPressed ?? false
        let padRS: Bool = pad?.rightShoulder.isPressed ?? false
        let padMenu: Bool = pad?.buttonMenu.isPressed ?? false
        let padUp: Bool = pad?.dpad.up.isPressed ?? false
        let padStick: Bool = pad?.leftThumbstickButton?.isPressed ?? false

        let padAEdge: Bool = edge("padA", padA)
        let padBEdge: Bool = edge("padB", padB)
        let padYEdge: Bool = edge("padY", padY)
        let padLSEdge: Bool = edge("padLS", padLS)
        let padRSEdge: Bool = edge("padRS", padRS)
        let padMenuEdge: Bool = edge("padMenu", padMenu)
        let padUpEdge: Bool = edge("padUp", padUp)

        let kEsc: Bool = edge("kEsc", key(kb, GCKeyCode.escape) || key(kb, GCKeyCode.keyP))
        let kE: Bool = edge("kE", key(kb, GCKeyCode.keyE))
        let kC: Bool = edge("kC", key(kb, GCKeyCode.keyC))
        let kL: Bool = edge("kL", key(kb, GCKeyCode.keyL))
        let kSpace: Bool = edge("kSpace", key(kb, GCKeyCode.spacebar))
        let kX: Bool = edge("kX", key(kb, GCKeyCode.keyX))
        let kZ: Bool = edge("kZ", key(kb, GCKeyCode.keyZ))
        let kM: Bool = edge("kM", key(kb, GCKeyCode.keyM))

        s.pause = tapPause || padMenuEdge || kEsc
        s.map = tapMap || kM
        s.interact = tapInteract || padAEdge || kE
        s.cameraToggle = tapCamera || padYEdge || kC

        switch context {
        case .driving:
            buildDriving(&s, dt: dt, controls: c, pad: pad, kb: kb)
            s.shiftUp = tapShiftUp || padRSEdge || kX
            s.shiftDown = tapShiftDown || padLSEdge || kZ
            s.lights = tapLights || padUpEdge || kL
            s.handbrake = touch.handbrake || padX || key(kb, GCKeyCode.spacebar)
            s.horn = touch.hornHeld || padB || key(kb, GCKeyCode.keyH)
            let look: (Float, Float) = lookDelta(controls: c, pad: pad)
            s.lookDX = look.0
            s.lookDY = look.1
        case .onFoot:
            buildOnFoot(&s, dt: dt, controls: c, pad: pad, kb: kb, padStick: padStick, padLS: padLS)
            s.jump = tapJump || padBEdge || kSpace
            s.lights = tapLights || kL
            let look: (Float, Float) = lookDelta(controls: c, pad: pad)
            s.lookDX = look.0
            s.lookDY = look.1
        case .menu:
            touch.lookDX = 0
            touch.lookDY = 0
        }

        state = s
        publishVisuals(finalSteer: s.steer)
    }

    // MARK: - Driving / on foot

    private func buildDriving(_ s: inout InputState, dt: Float, controls c: ControlSettings, pad: GCExtendedGamepad?, kb: GCKeyboardInput?) {
        // touch pedals ramp a little so a tap does not slam the throttle
        touchGas = touch.gas > 0.5 ? min(1, touchGas + dt * 5.0) : max(0, touchGas - dt * 9.0)
        touchBrake = touch.brake > 0.5 ? min(1, touchBrake + dt * 6.0) : max(0, touchBrake - dt * 10.0)

        var throttle: Float = touchGas
        var brake: Float = touchBrake
        var padSteer: Float = 0
        if let p = pad {
            throttle = max(throttle, p.rightTrigger.value)
            brake = max(brake, p.leftTrigger.value)
            padSteer = -inputDeadzone(p.leftThumbstick.xAxis.value, 0.1)
        }
        if key(kb, GCKeyCode.keyW) || key(kb, GCKeyCode.upArrow) { throttle = 1 }
        if key(kb, GCKeyCode.keyS) || key(kb, GCKeyCode.downArrow) { brake = 1 }

        let keyLeft: Bool = key(kb, GCKeyCode.keyA) || key(kb, GCKeyCode.leftArrow)
        let keyRight: Bool = key(kb, GCKeyCode.keyD) || key(kb, GCKeyCode.rightArrow)
        let keyTarget: Float = (keyLeft ? 1 : 0) - (keyRight ? 1 : 0)
        keySteer = inputMoveToward(keySteer, keyTarget, dt * (keyTarget == 0 ? 6.0 : 3.2))

        var modeSteer: Float = 0
        switch c.steering {
        case .tilt:
            modeSteer = tiltFiltered
        case .touchWheel:
            modeSteer = clampf(touch.steerWheel * c.touchSteerSensitivity, -1, 1)
        case .touchButtons:
            let target: Float = (touch.leftDown ? 1 : 0) - (touch.rightDown ? 1 : 0)
            var rate: Float = target == 0 ? 7.0 : 3.0 * c.touchSteerSensitivity
            if target != 0 && buttonSteer * target < 0 { rate *= 2.5 }
            buttonSteer = inputMoveToward(buttonSteer, target, dt * rate)
            modeSteer = buttonSteer
        }
        var steer: Float = modeSteer
        if abs(padSteer) > abs(steer) { steer = padSteer }
        if abs(keySteer) > abs(steer) { steer = keySteer }

        if c.autoThrottle && brake < 0.05 { throttle = 1 }

        s.steer = clampf(steer, -1, 1)
        s.throttle = clampf(throttle, 0, 1)
        s.brake = clampf(brake, 0, 1)
    }

    private func buildOnFoot(_ s: inout InputState, dt: Float, controls c: ControlSettings, pad: GCExtendedGamepad?, kb: GCKeyboardInput?, padStick: Bool, padLS: Bool) {
        var mx: Float = touch.moveX
        var my: Float = touch.moveY
        if let p = pad {
            mx += inputDeadzone(p.leftThumbstick.xAxis.value, 0.12)
            my += inputDeadzone(p.leftThumbstick.yAxis.value, 0.12)
        }
        if key(kb, GCKeyCode.keyD) || key(kb, GCKeyCode.rightArrow) { mx += 1 }
        if key(kb, GCKeyCode.keyA) || key(kb, GCKeyCode.leftArrow) { mx -= 1 }
        if key(kb, GCKeyCode.keyW) || key(kb, GCKeyCode.upArrow) { my += 1 }
        if key(kb, GCKeyCode.keyS) || key(kb, GCKeyCode.downArrow) { my -= 1 }
        let len: Float = sqrtf(mx * mx + my * my)
        if len > 1 {
            mx /= len
            my /= len
        }
        s.moveX = mx
        s.moveY = my
        let shiftHeld: Bool = key(kb, GCKeyCode.leftShift) || key(kb, GCKeyCode.rightShift)
        s.run = touch.runHeld || shiftHeld || padStick || padLS
    }

    /// look drag (touch points) + right stick, converted to radians for this frame (see the header of InputTypes.swift)
    private func lookDelta(controls c: ControlSettings, pad: GCExtendedGamepad?) -> (Float, Float) {
        let k: Float = 0.0032 * c.cameraSensitivity
        var lx: Float = touch.lookDX * k
        var ly: Float = touch.lookDY * k
        touch.lookDX = 0
        touch.lookDY = 0
        if let p = pad {
            let rate: Float = 2.4 * c.cameraSensitivity * (1.0 / 60.0)
            lx += inputDeadzone(p.rightThumbstick.xAxis.value, 0.12) * rate
            ly -= inputDeadzone(p.rightThumbstick.yAxis.value, 0.12) * rate
        }
        if c.invertLookY { ly = -ly }
        return (lx, ly)
    }

    // MARK: - Tilt

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                let o: UIInterfaceOrientation = windowScene.interfaceOrientation
                if o.isLandscape { return o }
            }
        }
        let legacy: UIInterfaceOrientation = UIApplication.shared.statusBarOrientation
        if legacy.isLandscape { return legacy }
        return UIInterfaceOrientation.landscapeRight
    }

    /// Roll of the phone about the screen normal (radians, clockwise as seen by the player = positive), from the gravity vector
    /// projected on the screen plane. Returns nil while the phone lies (almost) flat.
    private func computeRoll(gravity g: CMAcceleration, orientation: UIInterfaceOrientation) -> Float? {
        let gx: Float = Float(g.x)
        let gy: Float = Float(g.y)
        var gUp: Float = gy
        var gRight: Float = gx
        switch orientation {
        case .landscapeRight:          // home button on the right: device +x points up on screen, device -y points right
            gUp = gx
            gRight = -gy
        case .landscapeLeft:           // home button on the left: device -x points up on screen, device +y points right
            gUp = -gx
            gRight = gy
        case .portraitUpsideDown:
            gUp = -gy
            gRight = -gx
        default:
            gUp = gy
            gRight = gx
        }
        let planar: Float = sqrtf(gUp * gUp + gRight * gRight)
        if planar < 0.2 { return nil }
        return atan2f(gRight, -gUp)
    }

    private func updateTilt(dt: Float, controls c: ControlSettings) {
        guard motionRunning, let dm = motion.deviceMotion else { return }
        let orientation: UIInterfaceOrientation = currentInterfaceOrientation()
        if let roll = computeRoll(gravity: dm.gravity, orientation: orientation) {
            tiltRaw = roll
            if !tiltHaveSample {
                tiltHaveSample = true
                tiltNeutral = roll
            }
        }
        if !tiltHaveSample { return }

        // first use: calibrate shortly after the player starts driving
        if !tiltCalibrated && context == InputContext.driving {
            autoCalibrateTimer -= dt
            if autoCalibrateTimer <= 0 { calibrateTilt() }
        }

        let deltaDeg: Float = wrapAngle(tiltRaw - tiltNeutral) * Float.rad2deg
        let range: Float = max(8, c.tiltRangeDegrees)
        var n: Float = clampf((-deltaDeg / range) * c.tiltSensitivity, -1.5, 1.5)
        let a: Float = abs(n)
        let dz: Float = clampf(c.tiltDeadzone, 0, 0.5)
        var shaped: Float = a < dz ? 0 : (a - dz) / (1 - dz)
        shaped = min(1, shaped)
        shaped = powf(shaped, 1.25)
        n = n < 0 ? -shaped : shaped

        let lambda: Float = lerpf(90, 5, clampf(c.tiltSmoothing, 0, 1))
        tiltFiltered = damp(tiltFiltered, n, lambda, dt)

        if abs(steerVisuals.tilt - tiltFiltered) > 0.003 { steerVisuals.tilt = tiltFiltered }
        if abs(steerVisuals.tiltRollDegrees - deltaDeg) > 0.2 { steerVisuals.tiltRollDegrees = deltaDeg }
    }

    private func contextDidChange(from old: InputContext) {
        buttonSteer = 0
        keySteer = 0
        touchGas = 0
        touchBrake = 0
        if context == InputContext.driving && !tiltCalibrated { autoCalibrateTimer = 0.8 }
    }

    // MARK: - Devices

    private func activePad() -> GCExtendedGamepad? {
        for controller in GCController.controllers() {
            if let g = controller.extendedGamepad { return g }
        }
        return nil
    }

    private func key(_ kb: GCKeyboardInput?, _ code: GCKeyCode) -> Bool {
        guard let keyboard = kb, let button = keyboard.button(forKeyCode: code) else { return false }
        return button.isPressed
    }

    private func edge(_ name: String, _ now: Bool) -> Bool {
        let was: Bool = previousDown[name] ?? false
        previousDown[name] = now
        return now && !was
    }

    private func registerControllerObservers() {
        let center: NotificationCenter = NotificationCenter.default
        connectObserver = center.addObserver(forName: NSNotification.Name.GCControllerDidConnect, object: nil, queue: OperationQueue.main) { [weak self] _ in
            Task { @MainActor in
                self?.controllersChanged(connected: true)
            }
        }
        disconnectObserver = center.addObserver(forName: NSNotification.Name.GCControllerDidDisconnect, object: nil, queue: OperationQueue.main) { [weak self] _ in
            Task { @MainActor in
                self?.controllersChanged(connected: false)
            }
        }
    }

    private func controllersChanged(connected: Bool) {
        visuals.padConnected = !GCController.controllers().isEmpty
        ctx.toast(connected ? "Controller connected" : "Controller disconnected")
    }

    // MARK: - Publishing (only when something visibly changed)

    private func publishVisuals(finalSteer: Float) {
        if abs(steerVisuals.wheel - touch.steerWheel) > 0.003 { steerVisuals.wheel = touch.steerWheel }
        if abs(steerVisuals.steer - finalSteer) > 0.003 { steerVisuals.steer = finalSteer }
    }
}
