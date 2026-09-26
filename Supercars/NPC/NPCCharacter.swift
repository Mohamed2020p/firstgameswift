import Foundation
import SceneKit
import simd

// MARK: - NPCCharacter: one pooled pedestrian.  Owns its scene node (feet at y = 0, faces +Z), its skinned model, the animator and the
// kinematic controller (acceleration, deceleration, angular speed limits, turn-before-move).  The brain only chooses targets and speeds;
// this class turns them into believable motion, so nothing can accelerate, rotate or snap instantly.

@MainActor
final class NPCCharacter {
    let slot: Int
    let archetype: String
    let node = SCNNode()
    private(set) var model: SCNNode
    let animator: NPCAnimator
    private var baseMaterials: [ObjectIdentifier: [SCNMaterial]] = [:]

    // identity / look
    private(set) var identity: NPCIdentity
    private(set) var appearance: NPCAppearance
    private(set) var traits: NPCTraits
    var rng: SeededRNG
    let meta: NPCMeta.Archetype?

    // lifecycle
    var isActive: Bool = false
    var level: NPCLevel = NPCLevel.near
    var requestDespawn: Bool = false
    var age: Float = 0
    var reactCooldown: Float = 0
    var taxiAssigned: Bool = false

    // kinematics (metres, radians, world XZ)
    var pos: Vec2 = Vec2(0, 0)
    var heading: Float = 0
    var speed: Float = 0
    var turnRate: Float = 0
    var turnInPlace: Float = 0
    var knock: Vec2 = Vec2(0, 0)                 // external velocity (being bumped) that decays
    let radius: Float = 0.30

    // brain outputs
    var target: Vec2? = nil
    var desiredSpeed: Float = 0
    var facingTarget: Float? = nil
    var state: NPCState = NPCState.idle
    var stateTime: Float = 0
    var walkSpeedPersonal: Float = 1.4

    // animation requests
    var gesture: NPCGesture = NPCGesture.none
    var gestureTime: Float = 0
    var gestureDuration: Float = 1
    var lookAt: Float = 0
    var sit: Float = 0

    // scheduling accumulators
    var brainAccum: Float = 0
    var moveAccum: Float = 0
    var animAccum: Float = 0

    // brain data
    let brain: NPCBrain

    init?(slot: Int, archetype: String, assets: AssetLibrary, variants: NPCVariantSystem) {
        guard let meta = variants.archetype(archetype) else { return nil }
        let m: SCNNode
        do {
            m = try assets.model(meta.file, uniqueGeometry: true)
        } catch {
            assetLog("NPC model \(meta.file) failed: \(error.localizedDescription)")
            return nil
        }
        guard let anim = NPCAnimator(model: m, seed: UInt64(slot) &* 7919 &+ 17) else { return nil }
        self.slot = slot
        self.archetype = archetype
        self.meta = meta
        self.model = m
        self.animator = anim
        let idn = NPCIdentity(id: slot, worldSeed: 1)
        self.identity = idn
        self.appearance = NPCAppearance(archetype: archetype)
        self.traits = idn.profile.traits
        self.rng = SeededRNG(seed: idn.behaviorSeed)
        self.brain = NPCBrain()
        node.name = "npc\(slot)"
        node.addChildNode(m)
        m.enumerateHierarchy { (n: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if let g = n.geometry {
                n.castsShadow = true
                n.categoryBitMask = 1 | 4
                self.baseMaterials[ObjectIdentifier(g)] = g.materials
            }
        }
        node.isHidden = true
    }

    // MARK: configuration

    /// (re)dresses and re-seeds this pedestrian for a new life
    func configure(id: Int, worldSeed: UInt64, variants: NPCVariantSystem, position: Vec2, heading h: Float) {
        identity = NPCIdentity(id: id, worldSeed: worldSeed)
        traits = identity.profile.traits
        rng = SeededRNG(seed: identity.behaviorSeed)
        appearance = variants.makeAppearance(archetype: archetype, seed: identity.appearanceSeed)
        variants.apply(appearance, to: model, baseMaterials: baseMaterials)
        let s: Float = appearance.scale
        model.simdScale = Vec3(s, s, s)
        walkSpeedPersonal = traits.walkSpeed * rng.float(0.94, 1.06)
        pos = position
        heading = h
        speed = 0
        turnRate = 0
        turnInPlace = 0
        knock = Vec2(0, 0)
        target = nil
        desiredSpeed = 0
        facingTarget = nil
        state = NPCState.idle
        stateTime = 0
        gesture = NPCGesture.none
        gestureTime = 0
        lookAt = 0
        sit = 0
        brainAccum = rng.float(0, 0.1)
        moveAccum = 0
        animAccum = 0
        requestDespawn = false
        age = 0
        reactCooldown = 0
        taxiAssigned = false
        brain.reset()
        isActive = true
        model.isHidden = false
        node.isHidden = false
        applyTransform()
    }

    func deactivate() {
        isActive = false
        node.isHidden = true
        target = nil
        speed = 0
        state = NPCState.idle
    }

    func applyTransform() {
        node.simdPosition = Vec3(pos.x, 0, pos.y)
        node.simdEulerAngles = Vec3(0, heading, 0)
    }

    func snapshot() -> NPCStateSnapshot {
        return NPCStateSnapshot(id: identity.id, archetype: archetype, x: pos.x, z: pos.y, heading: heading, speed: speed, state: state.rawValue)
    }

    // MARK: gestures

    func startGesture(_ g: NPCGesture, duration: Float) {
        gesture = g
        gestureTime = 0
        gestureDuration = max(0.3, duration)
    }

    var gestureProgress: Float {
        if gesture == NPCGesture.none { return 0 }
        return clampf(gestureTime / gestureDuration, 0, 1)
    }

    // MARK: motion

    /// Integrates the kinematic controller.  `colliders` may be empty (simplified collision for far pedestrians).
    func stepMotion(dt: Float, colliders: [Collider], neighbors: [Vec2]) {
        if dt <= 0 { return }
        // heading control
        var want: Vec2? = nil
        if let t = target {
            let d: Vec2 = t - pos
            let l: Float = simd_length(d)
            if l > 0.04 { want = d / l }
        }
        var allowed: Float = desiredSpeed
        var turnErr: Float = 0
        var headingGoal: Float? = nil
        if var dir = want {
            if !colliders.isEmpty {
                dir = PedCollision.steer(desired: dir, pos: pos, colliders: colliders, clearance: 1.5)
            }
            // keep a small personal distance from other pedestrians / the player
            var push: Vec2 = Vec2(0, 0)
            for o in neighbors {
                let d: Vec2 = pos - o
                let l: Float = simd_length(d)
                if l < 0.95 && l > 1e-3 { push += d / l * ((0.95 - l) / 0.95) }
            }
            if simd_length(push) > 0.01 {
                let mixed: Vec2 = dir + push * 1.1
                let ml: Float = simd_length(mixed)
                if ml > 1e-3 { dir = mixed / ml }
            }
            headingGoal = headingOf(dir)
        } else if let f = facingTarget, desiredSpeed < 0.05 {
            headingGoal = f
        }
        if let g = headingGoal {
            turnErr = angleDiff(heading, g)
            let maxRate: Float = lerpf(3.3, 1.9, clampf(speed / 3, 0, 1))
            let rate: Float = clampf(turnErr * 5.5, -maxRate, maxRate)
            heading = wrapAngle(heading + rate * dt)
            turnRate = damp(turnRate, rate, 14, dt)
        } else {
            turnRate = damp(turnRate, 0, 10, dt)
        }
        // turn before moving off: speed follows how well we face the way we want to go
        if want != nil {
            let align: Float = cosf(turnErr)
            allowed *= smoothstep(0.25, 0.85, align)
        } else {
            allowed = 0
        }
        turnInPlace = (abs(turnErr) > 0.45 && speed < 0.45 && headingGoal != nil) ? clampf(turnErr, -1, 1) : 0
        let accel: Float = 1.6 + 0.5 * (allowed > 3 ? 1 : 0)
        let decel: Float = 3.0
        speed += clampf(allowed - speed, -decel * dt, accel * dt)
        if speed < 0.02 && allowed < 0.02 { speed = 0 }

        // translate
        let fwd: Vec2 = headingForward2(heading)
        var np: Vec2 = pos + fwd * (speed * dt) + knock * dt
        knock = knock * expf(-5 * dt)
        if simd_length(knock) < 0.02 { knock = Vec2(0, 0) }
        if !colliders.isEmpty { PedCollision.resolve(&np, radius: radius, colliders: colliders) }
        // when a wall stops us, stop the legs too (no running on the spot)
        let moved: Float = simd_length(np - pos) / dt
        if speed > 0.5 && moved < speed * 0.3 && simd_length(knock) < 0.1 { speed = max(moved, 0) }
        pos = np
        applyTransform()
    }

    /// Advances the animation.  Called every frame for near pedestrians, at a reduced rate for mid ones.
    func animate(dt: Float) {
        stateTime += dt
        if gesture != NPCGesture.none {
            gestureTime += dt
            if gestureTime >= gestureDuration { gesture = NPCGesture.none }
        }
        animator.update(dt: dt, speed: speed, turnRate: turnRate, turnInPlace: turnInPlace, gesture: gesture, gestureProgress: gestureProgress,
                        lookAt: lookAt, sit: sit, traits: traits)
    }
}
