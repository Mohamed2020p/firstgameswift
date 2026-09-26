import Foundation

/// Something the on-foot player can use (door, bed, garage console, car door …).
/// `GameContext` scans all interactables every frame while the player is on foot; the nearest enabled one inside its radius shows
/// `prompt` on the HUD and runs `action` when the player taps Interact.
struct Interactable {
    let id: String
    var position: Vec3
    var radius: Float
    var prompt: String
    var isEnabled: () -> Bool
    var action: () -> Void

    init(id: String, position: Vec3, radius: Float, prompt: String, isEnabled: @escaping () -> Bool = { true }, action: @escaping () -> Void) {
        self.id = id
        self.position = position
        self.radius = radius
        self.prompt = prompt
        self.isEnabled = isEnabled
        self.action = action
    }
}
