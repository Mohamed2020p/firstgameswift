import Foundation
import AVFoundation
import QuartzCore
import simd

// MARK: - AudioManager: everything is synthesised offline (tools/make_audio*.py) into Resources/Audio/*.m4a.
//   * one shots (SFX) through a pool of player voices; positional ones go through an AVAudioEnvironmentNode (source positions are
//     converted into the listener's frame so the listener can stay at the origin)
//   * the engine: 4 RPM layers + a decel layer per engine type, crossfaded by RPM and pitch-shifted (AVAudioUnitVarispeed)
//   * tyre skid / kerb / gravel / wind / road loops driven by the vehicle
//   * music + ambience: two stereo voices each, crossfaded when the track changes
//   Loops follow tools/make_audio.py: the file holds head + L + tail frames, the loop window is [loopHead, loopHead + L).

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { return nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct EngineLayerInfo: Decodable {
    let layer: String
    let file: String
    let refRPM: Float
    let minRPM: Float
    let maxRPM: Float
    let loopFrames: Int?
    let synthRPM: Float?
}

private struct EngineEntry: Decodable {
    let layers: [EngineLayerInfo]
    let idleRPM: Float
    let redlineRPM: Float
    let decel: EngineLayerInfo?
}

private struct LoopFileInfo: Decodable {
    let loopFrames: Int
    let channels: Int
}

private struct AudioTable: Decodable {
    var loopHead: Int = 8192
    var loops: [String: LoopFileInfo] = [:]
    var engines: [String: EngineEntry] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        if let k = DynamicKey(stringValue: "loopHead") { loopHead = (try? c.decode(Int.self, forKey: k)) ?? 8192 }
        if let k = DynamicKey(stringValue: "loops") { loops = (try? c.decode([String: LoopFileInfo].self, forKey: k)) ?? [:] }
        for name in ["v6", "v8", "v10", "v12", "v16"] {
            if let k = DynamicKey(stringValue: name), let e = try? c.decode(EngineEntry.self, forKey: k) { engines[name] = e }
        }
    }
}

private struct BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
}

@MainActor
private final class OneShotVoice {
    let player = AVAudioPlayerNode()
    let varispeed = AVAudioUnitVarispeed()
    let positional: Bool
    var busy: Bool = false
    var startedAt: Double = 0
    var generation: Int = 0
    init(positional: Bool) { self.positional = positional }
}

@MainActor
private final class LoopVoice {
    let player = AVAudioPlayerNode()
    let varispeed = AVAudioUnitVarispeed()
    let channels: AVAudioChannelCount
    var buffer: AVAudioPCMBuffer? = nil
    var name: String = ""
    var current: Float = 0
    var target: Float = 0
    var playing: Bool = false
    init(channels: AVAudioChannelCount) { self.channels = channels }

    func assign(_ b: AVAudioPCMBuffer?, name: String) {
        stop()
        buffer = nil
        if let b = b, b.format.channelCount == channels {
            buffer = b
            self.name = name
        } else {
            self.name = ""
        }
    }

    func start(running: Bool) {
        guard running, let b = buffer else { return }
        player.stop()
        player.scheduleBuffer(b, at: nil, options: AVAudioPlayerNodeBufferOptions.loops, completionHandler: nil)
        player.play()
        playing = true
    }

    func stop() {
        if playing { player.stop() }
        playing = false
    }
}

@MainActor
final class AudioManager {
    private unowned let ctx: GameContext
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let sfxBus = AVAudioMixerNode()
    private let vehicleBus = AVAudioMixerNode()
    private let musicBus = AVAudioMixerNode()
    private let ambBus = AVAudioMixerNode()

    private var started = false
    private var graphBuilt = false
    private var table = AudioTable()
    private var tableLoaded = false

    private var positionalVoices: [OneShotVoice] = []
    private var flatVoices: [OneShotVoice] = []
    private var sfxBuffers: [String: AVAudioPCMBuffer] = [:]

    // vehicle loops
    private var engineVoices: [LoopVoice] = []
    private var skidAsphalt: LoopVoice? = nil
    private var skidGrass: LoopVoice? = nil
    private var kerbLoop: LoopVoice? = nil
    private var gravelLoop: LoopVoice? = nil
    private var windLoop: LoopVoice? = nil
    private var roadLoop: LoopVoice? = nil
    private var currentEngine: EngineType? = nil
    private var engineLayerInfos: [EngineLayerInfo] = []
    private var engineDecelInfo: EngineLayerInfo? = nil
    private var engineActive = false
    private var engineEnableAt: Double = 0
    private var engineLevel: Float = 0
    private var lastTyreUpdate: Double = 0
    private var lastSurfaceHard = true
    private var loopCache: [String: AVAudioPCMBuffer] = [:]

    // music + ambience
    private var musicVoices: [LoopVoice] = []
    private var ambVoices: [LoopVoice] = []
    private var requestedMusic: MusicTrack? = nil
    private var requestedAmbience: AmbienceTrack? = nil
    private var activeMusicName: String? = nil
    private var activeAmbName: String? = nil
    private var pendingMusicName: String? = nil
    private var pendingAmbName: String? = nil
    private var lastFadeTime: Double = 0
    private var lastSelectCheck: Double = 0

    // listener
    private var listenerPos = Vec3(0, 0, 0)
    private var listenerFwd = Vec3(0, 0, 1)

    private let monoFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private let stereoFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    init(ctx: GameContext) {
        self.ctx = ctx
    }

    // MARK: - Start / graph

    func start() {
        if started { return }
        started = true
        configureSession()
        loadTable()
        buildGraph()
        do {
            engine.prepare()
            try engine.start()
        } catch {
            assetLog("audio engine failed to start: \(error.localizedDescription)")
            started = false
            return
        }
        applySettings()
        startPersistentLoops()
        observeSystemEvents()
        preloadSFX()
        // music / ambience requested before the engine existed
        if let m = requestedMusic { setMusic(m) }
        if let a = requestedAmbience { setAmbience(a) }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(AVAudioSession.Category.playback, mode: AVAudioSession.Mode.default, options: [])
            try session.setActive(true)
        } catch {
            assetLog("audio session: \(error.localizedDescription)")
        }
    }

    private func loadTable() {
        if tableLoaded { return }
        tableLoaded = true
        if let t = try? ctx.assets.json("engine_audio", as: AudioTable.self) { table = t }
    }

    private func attachLoop(_ v: LoopVoice, to bus: AVAudioMixerNode) {
        engine.attach(v.player)
        engine.attach(v.varispeed)
        let f: AVAudioFormat = v.channels == 1 ? monoFormat : stereoFormat
        engine.connect(v.player, to: v.varispeed, format: f)
        engine.connect(v.varispeed, to: bus, format: f)
        v.player.volume = 0
    }

    private func buildGraph() {
        if graphBuilt { return }
        graphBuilt = true
        let main: AVAudioMixerNode = engine.mainMixerNode
        for n in [sfxBus, vehicleBus, musicBus, ambBus] {
            engine.attach(n)
            engine.connect(n, to: main, format: nil)
        }
        engine.attach(environment)
        engine.connect(environment, to: main, format: nil)
        environment.distanceAttenuationParameters.distanceAttenuationModel = AVAudioEnvironmentDistanceAttenuationModel.inverse
        environment.distanceAttenuationParameters.referenceDistance = 5
        environment.distanceAttenuationParameters.maximumDistance = 300
        environment.distanceAttenuationParameters.rolloffFactor = 1.1
        environment.reverbParameters.enable = false

        for _ in 0..<10 {
            let v = OneShotVoice(positional: true)
            engine.attach(v.player)
            engine.attach(v.varispeed)
            engine.connect(v.player, to: v.varispeed, format: monoFormat)
            engine.connect(v.varispeed, to: environment, format: monoFormat)
            v.player.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithm.equalPowerPanning
            v.player.sourceMode = AVAudio3DMixingSourceMode.pointSource
            positionalVoices.append(v)
        }
        for _ in 0..<10 {
            let v = OneShotVoice(positional: false)
            engine.attach(v.player)
            engine.attach(v.varispeed)
            engine.connect(v.player, to: v.varispeed, format: monoFormat)
            engine.connect(v.varispeed, to: sfxBus, format: monoFormat)
            flatVoices.append(v)
        }
        for _ in 0..<5 {
            let v = LoopVoice(channels: 1)
            attachLoop(v, to: vehicleBus)
            engineVoices.append(v)
        }
        skidAsphalt = makeLoop(1, vehicleBus)
        skidGrass = makeLoop(1, vehicleBus)
        kerbLoop = makeLoop(1, vehicleBus)
        gravelLoop = makeLoop(1, vehicleBus)
        windLoop = makeLoop(1, vehicleBus)
        roadLoop = makeLoop(1, vehicleBus)
        for _ in 0..<2 {
            let m = LoopVoice(channels: 2)
            attachLoop(m, to: musicBus)
            musicVoices.append(m)
            let a = LoopVoice(channels: 2)
            attachLoop(a, to: ambBus)
            ambVoices.append(a)
        }
    }

    private func makeLoop(_ ch: AVAudioChannelCount, _ bus: AVAudioMixerNode) -> LoopVoice {
        let v = LoopVoice(channels: ch)
        attachLoop(v, to: bus)
        return v
    }

    private func startPersistentLoops() {
        let pairs: [(LoopVoice?, String)] = [(skidAsphalt, "tyreSkidAsphalt"), (skidGrass, "tyreSkidGrass"), (kerbLoop, "kerbRumble"),
                                             (gravelLoop, "gravelRoll"), (windLoop, "wind_loop"), (roadLoop, "road_loop")]
        for p in pairs {
            guard let v = p.0 else { continue }
            v.assign(loopBuffer(p.1), name: p.1)
            v.start(running: engine.isRunning)
        }
    }

    // MARK: - Decoding

    private nonisolated static func decodeFile(url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames: AVAudioFrameCount = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
        do {
            try file.read(into: buf)
        } catch {
            return nil
        }
        return buf
    }

    private nonisolated static func sliceLoop(_ src: AVAudioPCMBuffer, head: Int, frames: Int) -> AVAudioPCMBuffer? {
        let total: Int = Int(src.frameLength)
        if frames <= 0 || head + frames > total {
            return src
        }
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(frames)),
              let sp = src.floatChannelData, let dp = dst.floatChannelData else { return src }
        for ch in 0..<Int(src.format.channelCount) {
            memcpy(dp[ch], sp[ch].advanced(by: head), frames * MemoryLayout<Float>.size)
        }
        dst.frameLength = AVAudioFrameCount(frames)
        return dst
    }

    /// decoded + sliced loop window (cached, synchronous: only used for small files)
    private func loopBuffer(_ name: String) -> AVAudioPCMBuffer? {
        if let b = loopCache[name] { return b }
        guard let url = ctx.assets.audioURL(name), let raw = AudioManager.decodeFile(url: url) else { return nil }
        let info: LoopFileInfo? = table.loops[name]
        let out: AVAudioPCMBuffer? = AudioManager.sliceLoop(raw, head: table.loopHead, frames: info?.loopFrames ?? 0)
        if let o = out { loopCache[name] = o }
        return out
    }

    private func preloadSFX() {
        var urls: [(String, URL)] = []
        for s in SFX.allCases {
            if let u = ctx.assets.audioURL(s.rawValue) { urls.append((s.rawValue, u)) }
        }
        let jobs = urls
        Task { @MainActor [weak self] in
            for j in jobs {
                let box: BufferBox = await Task.detached(priority: .utility) { () -> BufferBox in
                    return BufferBox(buffer: AudioManager.decodeFile(url: j.1))
                }.value
                if let b = box.buffer, b.format.channelCount == 1 { self?.sfxBuffers[j.0] = b }
            }
        }
    }

    private func sfxBuffer(_ s: SFX) -> AVAudioPCMBuffer? {
        if let b = sfxBuffers[s.rawValue] { return b }
        guard let url = ctx.assets.audioURL(s.rawValue), let b = AudioManager.decodeFile(url: url), b.format.channelCount == 1 else { return nil }
        sfxBuffers[s.rawValue] = b
        return b
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: OperationQueue.main) { [weak self] note in
            let raw: UInt? = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self = self else { return }
                if let r = raw, AVAudioSession.InterruptionType(rawValue: r) == AVAudioSession.InterruptionType.ended {
                    self.recover()
                }
            }
        }
        nc.addObserver(forName: Notification.Name.AVAudioEngineConfigurationChange, object: engine, queue: OperationQueue.main) { [weak self] _ in
            Task { @MainActor in self?.recover() }
        }
    }

    private func recover() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return }
        }
        for v in engineVoices { v.start(running: true) }
        for v in [skidAsphalt, skidGrass, kerbLoop, gravelLoop, windLoop, roadLoop] { v?.start(running: true) }
        for v in musicVoices where v.buffer != nil { v.start(running: true) }
        for v in ambVoices where v.buffer != nil { v.start(running: true) }
    }

    // MARK: - One shots

    private func acquire(_ pool: [OneShotVoice]) -> OneShotVoice? {
        for v in pool where !v.busy { return v }
        var oldest: OneShotVoice? = nil
        for v in pool {
            if oldest == nil || v.startedAt < (oldest?.startedAt ?? 0) { oldest = v }
        }
        return oldest
    }

    /// world position -> the listener's frame (listener sits at the origin looking down -Z, +X right)
    private func relative(_ p: Vec3) -> AVAudio3DPoint {
        let rel: Vec3 = p - listenerPos
        let f: Vec3 = listenerFwd
        var right: Vec3 = simd_cross(f, Vec3(0, 1, 0))
        if simd_length(right) < 1e-3 { right = Vec3(1, 0, 0) }
        right = right.normalizedSafe
        let up: Vec3 = simd_cross(right, f).normalizedSafe
        return AVAudio3DPoint(x: simd_dot(rel, right), y: simd_dot(rel, up), z: -simd_dot(rel, f))
    }

    func play(_ sfx: SFX, volume: Float = 1, rate: Float = 1, position: Vec3? = nil) {
        if !started { start() }
        guard started, engine.isRunning else { return }
        guard let buf = sfxBuffer(sfx) else { return }
        let positional: Bool = position != nil
        guard let v = acquire(positional ? positionalVoices : flatVoices) else { return }
        v.generation += 1
        let gen: Int = v.generation
        v.player.stop()
        v.busy = true
        v.startedAt = CACurrentMediaTime()
        v.varispeed.rate = clampf(rate, 0.25, 4.0)
        v.player.volume = clampf(volume, 0, 2)
        if let p = position { v.player.position = relative(p) }
        v.player.scheduleBuffer(buf, at: nil, options: AVAudioPlayerNodeBufferOptions.interrupts, completionCallbackType: AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack) { [weak v] _ in
            Task { @MainActor in
                if let vv = v, vv.generation == gen { vv.busy = false }
            }
        }
        v.player.play()
    }

    // MARK: - Engine

    private func engineKey(_ t: EngineType) -> String { return t.rawValue }

    func engineStart(type: EngineType) {
        if !started { start() }
        guard started else { return }
        loadTable()
        if currentEngine != type {
            currentEngine = type
            for v in engineVoices { v.stop(); v.buffer = nil }
            engineLayerInfos = []
            engineDecelInfo = nil
            if let e = table.engines[engineKey(type)] {
                engineLayerInfos = e.layers
                engineDecelInfo = e.decel
                var i = 0
                for l in e.layers where i < 4 {
                    engineVoices[i].assign(loopBuffer(l.file), name: l.file)
                    i += 1
                }
                if let d = e.decel { engineVoices[4].assign(loopBuffer(d.file), name: d.file) }
            } else {
                // fall back to whatever engine exists (V8 is always generated first)
                if let e = table.engines["v8"] {
                    engineLayerInfos = e.layers
                    engineDecelInfo = e.decel
                    var i = 0
                    for l in e.layers where i < 4 {
                        engineVoices[i].assign(loopBuffer(l.file), name: l.file)
                        i += 1
                    }
                    if let d = e.decel { engineVoices[4].assign(loopBuffer(d.file), name: d.file) }
                }
            }
        }
        for v in engineVoices {
            v.player.volume = 0
            v.start(running: engine.isRunning)
        }
        engineActive = true
        engineEnableAt = CACurrentMediaTime() + 0.85
        engineLevel = 0
        play(SFX.engineStart, volume: 0.9, rate: 1, position: nil)
    }

    func engineStop() {
        if engineActive { play(SFX.engineStop, volume: 0.8, rate: 1, position: nil) }
        engineActive = false
        for v in engineVoices { v.player.volume = 0 }
        for v in [skidAsphalt, skidGrass, kerbLoop, gravelLoop, windLoop, roadLoop] { v?.player.volume = 0 }
    }

    /// called every frame while driving
    func updateEngine(rpm: Float, throttle: Float, load: Float, speed: Float) {
        guard started, engineActive, !engineLayerInfos.isEmpty else { return }
        let now: Double = CACurrentMediaTime()
        let target: Float = now >= engineEnableAt ? 1 : 0
        engineLevel = engineLevel + clampf(target - engineLevel, -0.2, 0.05)
        var weights: [Float] = []
        var sum: Float = 0
        for l in engineLayerInfos {
            var w: Float = 0
            if rpm >= l.minRPM && rpm <= l.maxRPM {
                if rpm <= l.refRPM {
                    w = smoothstep(l.minRPM, l.refRPM, rpm)
                } else {
                    w = 1 - smoothstep(l.refRPM, l.maxRPM, rpm)
                }
            }
            if l.layer == "idle" && rpm < l.refRPM { w = 1 }
            if l.layer == "high" && rpm > l.refRPM { w = 1 }
            weights.append(w)
            sum += w
        }
        if sum < 0.001 { weights[0] = 1; sum = 1 }
        // engine braking layer
        var decelW: Float = 0
        if let d = engineDecelInfo {
            let off: Float = clampf(1 - throttle * 1.6, 0, 1)
            let highRev: Float = smoothstep(d.minRPM + 400, d.refRPM, rpm)
            decelW = off * off * highRev
        }
        let eng: Float = ctx.settings.settings.audio.engine
        let loadGain: Float = 0.5 + 0.5 * clampf(load, 0, 1)
        let idleBoost: Float = 1.0
        for (i, l) in engineLayerInfos.enumerated() where i < 4 {
            let v: LoopVoice = engineVoices[i]
            let share: Float = sqrtf(weights[i] / sum)
            let synth: Float = l.synthRPM ?? l.refRPM
            let pitch: Float = clampf(rpm / max(synth, 200), 0.4, 2.6)
            v.varispeed.rate = pitch
            v.player.volume = share * loadGain * (1 - 0.65 * decelW) * engineLevel * idleBoost * eng
        }
        if let d = engineDecelInfo {
            let v: LoopVoice = engineVoices[4]
            let synth: Float = d.synthRPM ?? d.refRPM
            v.varispeed.rate = clampf(rpm / max(synth, 200), 0.4, 2.6)
            v.player.volume = decelW * 0.9 * engineLevel * eng
        }
        // road + wind noise from speed
        let s: Float = min(1, abs(speed) / 70)
        roadLoop?.player.volume = (lastSurfaceHard ? 0.55 : 0.25) * s * s * engineLevel
        roadLoop?.varispeed.rate = 0.8 + 0.5 * s
    }

    func updateTyres(skid: Float, surface: SurfaceType, rumble: Float, wind: Float) {
        guard started, engineActive else { return }
        lastTyreUpdate = CACurrentMediaTime()
        let hard: Bool = surface == SurfaceType.asphalt || surface == SurfaceType.concrete
        lastSurfaceHard = hard || surface == SurfaceType.sidewalk
        let s: Float = clampf(skid, 0, 1)
        skidAsphalt?.player.volume = hard ? s * 0.9 : 0
        skidAsphalt?.varispeed.rate = 0.92 + 0.2 * s
        skidGrass?.player.volume = (surface == SurfaceType.grass || surface == SurfaceType.dirt) ? s * 0.9 : 0
        kerbLoop?.player.volume = surface == SurfaceType.sidewalk ? clampf(rumble, 0, 1) * 0.9 : 0
        gravelLoop?.player.volume = (surface == SurfaceType.dirt || surface == SurfaceType.grass) ? clampf(rumble, 0, 1) * 0.7 : 0
        windLoop?.player.volume = clampf(wind, 0, 1) * 0.6
        windLoop?.varispeed.rate = 0.9 + 0.4 * clampf(wind, 0, 1)
    }

    // MARK: - Music / ambience

    func setMusic(_ track: MusicTrack?) {
        requestedMusic = track
        if !started { return }
        evaluateSelection(force: true)
    }

    func setAmbience(_ track: AmbienceTrack?) {
        requestedAmbience = track
        if !started { return }
        evaluateSelection(force: true)
    }

    private func effectiveMusic() -> String? {
        guard let m = requestedMusic else { return nil }
        if m == MusicTrack.drive, let w = ctx.world {
            let t: Float = w.timeOfDay
            if t < 5.0 || t > 21.0 { return MusicTrack.night.rawValue }
        }
        return m.rawValue
    }

    private func effectiveAmbience() -> String? {
        guard let a = requestedAmbience else { return nil }
        if (a == AmbienceTrack.suburbDay || a == AmbienceTrack.suburbNight), let w = ctx.world {
            let d: Float = simd_length(Vec3(listenerPos.x, 0, listenerPos.z) - Vec3(w.spawn.house.position.x, 0, w.spawn.house.position.z))
            if d > 380 { return a == AmbienceTrack.suburbDay ? AmbienceTrack.cityDay.rawValue : AmbienceTrack.cityNight.rawValue }
        }
        return a.rawValue
    }

    private func evaluateSelection(force: Bool) {
        let m: String? = effectiveMusic()
        if m != activeMusicName || force {
            if m != activeMusicName { crossfade(to: m, voices: musicVoices, isMusic: true) }
        }
        let a: String? = effectiveAmbience()
        if a != activeAmbName || force {
            if a != activeAmbName { crossfade(to: a, voices: ambVoices, isMusic: false) }
        }
    }

    private func crossfade(to name: String?, voices: [LoopVoice], isMusic: Bool) {
        if isMusic { activeMusicName = name } else { activeAmbName = name }
        for v in voices where v.name != name { v.target = 0 }
        guard let n = name else { return }
        if let existing = voices.first(where: { $0.name == n }) {
            existing.target = 1
            return
        }
        // load in the background, then start on the idle voice
        guard let url = ctx.assets.audioURL(n) else { return }
        let head: Int = table.loopHead
        let frames: Int = table.loops[n]?.loopFrames ?? 0
        if isMusic { pendingMusicName = n } else { pendingAmbName = n }
        Task { @MainActor [weak self] in
            let box: BufferBox = await Task.detached(priority: .utility) { () -> BufferBox in
                guard let raw = AudioManager.decodeFile(url: url) else { return BufferBox(buffer: nil) }
                return BufferBox(buffer: AudioManager.sliceLoop(raw, head: head, frames: frames))
            }.value
            guard let self = self else { return }
            let current: String? = isMusic ? self.activeMusicName : self.activeAmbName
            if current != n { return }
            guard let buf = box.buffer else { return }
            let pool: [LoopVoice] = isMusic ? self.musicVoices : self.ambVoices
            var idle: LoopVoice? = pool.first(where: { $0.target == 0 && $0.current < 0.02 })
            if idle == nil { idle = pool.first(where: { $0.name != n }) }
            guard let v = idle else { return }
            v.assign(buf, name: n)
            v.current = 0
            v.target = 1
            v.player.volume = 0
            v.start(running: self.engine.isRunning)
        }
    }

    // MARK: - Listener + fades (called every frame by GameContext)

    func updateListener(position: Vec3, forward: Vec3) {
        listenerPos = position
        let f: Vec3 = forward.normalizedSafe
        if simd_length(f) > 0.5 { listenerFwd = f }
        guard started else { return }
        let now: Double = CACurrentMediaTime()
        var dt: Float = Float(now - lastFadeTime)
        lastFadeTime = now
        if dt > 0.25 || dt <= 0 { dt = 1.0 / 60.0 }
        if now - lastSelectCheck > 1.5 {
            lastSelectCheck = now
            evaluateSelection(force: false)
        }
        let s: AudioSettings = ctx.settings.settings.audio
        _ = s
        for v in musicVoices { fade(v, dt: dt, rate: 1.0 / 1.6, maxVolume: 0.85) }
        for v in ambVoices { fade(v, dt: dt, rate: 1.0 / 2.0, maxVolume: 0.9) }
        // vehicle loops go silent when the vehicle stops reporting
        if engineActive && now - lastTyreUpdate > 0.4 && lastTyreUpdate > 0 {
            for v in [skidAsphalt, skidGrass, kerbLoop, gravelLoop, windLoop] { v?.player.volume = 0 }
        }
    }

    private func fade(_ v: LoopVoice, dt: Float, rate: Float, maxVolume: Float) {
        if v.buffer == nil { return }
        if v.current != v.target {
            let step: Float = dt * rate
            v.current = v.current < v.target ? min(v.target, v.current + step) : max(v.target, v.current - step)
        }
        v.player.volume = v.current * maxVolume
        if v.current <= 0.001 && v.target == 0 && v.playing {
            v.stop()
            v.name = ""
        }
    }

    // MARK: - Settings

    func applySettings() {
        let a: AudioSettings = ctx.settings.settings.audio
        engine.mainMixerNode.outputVolume = clampf(a.master, 0, 1)
        sfxBus.outputVolume = clampf(a.sfx, 0, 1.5)
        environment.outputVolume = clampf(a.sfx, 0, 1.5)
        vehicleBus.outputVolume = clampf(a.engine, 0, 1.5)
        musicBus.outputVolume = clampf(a.music, 0, 1)
        ambBus.outputVolume = clampf(a.ambience, 0, 1)
    }
}
