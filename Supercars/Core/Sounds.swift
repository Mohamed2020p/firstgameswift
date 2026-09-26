import Foundation

// MARK: - Sound identifiers.  The audio pipeline (tools/make_audio.py) produces one file per rawValue in Resources/Audio/<rawValue>.m4a
// and AudioManager plays them by these ids.  Add a case here AND generate the file.

enum SFX: String, CaseIterable {
    // car
    case engineStart, engineStop, exhaustPop, gearShift, turboWhoosh, horn, headlightClick
    case tyreSkidAsphalt, tyreSkidGrass, kerbRumble, gravelRoll
    case crashMetalLight, crashMetalHeavy, crashGlass, scrape
    case lampBend, lampFall, treeCrack, treeFall, leavesRustle, signClang, debrisTumble
    case carDoorOpen, carDoorClose, seatbelt
    // on foot / house
    case footConcrete1, footConcrete2, footConcrete3, footGrass1, footGrass2, footWood1, footWood2, footWood3
    case doorOpen, doorClose, garageDoorMotor, liftMotor, bedRustle, sleepChime, lightSwitch, cashRegister, wrenchRatchet
    // ui / race
    case uiTap, uiBack, uiConfirm, uiSwipe, uiError, uiToggleOn, uiToggleOff
    case countdownBeep, raceGo, lapComplete, raceWin, raceLose, purchase
}

enum MusicTrack: String, CaseIterable {
    case menu, drive, race, garage, night
}

enum AmbienceTrack: String, CaseIterable {
    case cityDay, cityNight, suburbDay, suburbNight, houseInterior, garageInterior
}

/// Loops whose pitch follows engine RPM. Files: engine_<type>_<layer>.m4a  (layer: idle, low, mid, high) plus
/// engine_<type>_decel.m4a. `refRPM` is the rpm each layer was synthesised at (AudioManager pitch-shifts relative to it).
enum EngineLayer: String, CaseIterable { case idle, low, mid, high, decel }
