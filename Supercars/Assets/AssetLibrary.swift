import Foundation
import SceneKit
import UIKit

// MARK: - Errors + logging shared by the asset layer

enum AssetError: LocalizedError {
    case fileNotFound(String)
    case unreadable(String, String)
    case malformed(String, String)
    case unsupported(String, String)
    case decodeFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name): return "Asset '\(name)' was not found in the app bundle."
        case .unreadable(let name, let why): return "Asset '\(name)' could not be read: \(why)"
        case .malformed(let name, let why): return "Asset '\(name)' is malformed: \(why)"
        case .unsupported(let name, let why): return "Asset '\(name)' uses an unsupported feature: \(why)"
        case .decodeFailed(let name, let why): return "Asset '\(name)' could not be decoded: \(why)"
        }
    }
}

/// Asset-layer log line (loader statistics, warnings). Only called at load time, never per frame.
func assetLog(_ text: String) {
    print("[Assets] " + text)
}

// MARK: - AssetLibrary: bundle access with caching (Resources/Models, Textures, Data, Audio)

@MainActor
final class AssetLibrary {
    /// options used for every model unless overridden in `optionsByModel`
    var defaultOptions: GLBLoadOptions = GLBLoadOptions()
    var optionsByModel: [String: GLBLoadOptions] = [:]

    private var models: [String: GLBAsset] = [:]
    private var images: [String: UIImage] = [:]
    private var missingImages: Set<String> = []
    private var missingLogged: Set<String> = []

    init() {}

    // MARK: lookup

    private func locate(_ name: String, extensions: [String], directory: String) -> URL? {
        let bundle: Bundle = Bundle.main
        for ext in extensions {
            if let u = bundle.url(forResource: name, withExtension: ext, subdirectory: directory) { return u }
        }
        for ext in extensions {
            if let u = bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources/" + directory) { return u }
        }
        // resources added as a flat group end up in the bundle root
        for ext in extensions {
            if let u = bundle.url(forResource: name, withExtension: ext) { return u }
        }
        return nil
    }

    private func logMissingOnce(_ key: String, _ text: String) {
        if missingLogged.contains(key) { return }
        missingLogged.insert(key)
        assetLog(text)
    }

    private func options(for name: String) -> GLBLoadOptions {
        return optionsByModel[name] ?? defaultOptions
    }

    // MARK: models

    func hasModel(_ name: String) -> Bool {
        if models[name] != nil { return true }
        return locate(name, extensions: ["glb"], directory: "Models") != nil
    }

    private func asset(named name: String) throws -> GLBAsset {
        if let cached = models[name] { return cached }
        guard let url = locate(name, extensions: ["glb"], directory: "Models") else {
            logMissingOnce("model:" + name, "missing model \(name).glb")
            throw AssetError.fileNotFound(name + ".glb")
        }
        let parsed: GLBAsset = try GLBAsset.load(url: url, options: options(for: name))
        models[name] = parsed
        return parsed
    }

    /// Resources/Models/<name>.glb -> NEW node hierarchy each call (geometry + materials shared, skins re-bound per instance).
    func model(_ name: String, uniqueGeometry: Bool = false) throws -> SCNNode {
        let a: GLBAsset = try asset(named: name)
        return a.instantiate(uniqueGeometry: uniqueGeometry)
    }

    /// Parses (off the main thread) and caches models without instantiating them.
    func preload(_ names: [String]) async {
        for name in names {
            if models[name] != nil { continue }
            guard let url = locate(name, extensions: ["glb"], directory: "Models") else {
                logMissingOnce("model:" + name, "missing model \(name).glb")
                continue
            }
            let opts: GLBLoadOptions = options(for: name)
            let result: Result<GLBAsset, Error> = await Task.detached(priority: .userInitiated) { () -> Result<GLBAsset, Error> in
                do {
                    let loaded: GLBAsset = try GLBAsset.load(url: url, options: opts)
                    return Result<GLBAsset, Error>.success(loaded)
                } catch {
                    return Result<GLBAsset, Error>.failure(error)
                }
            }.value
            switch result {
            case .success(let a):
                if models[name] == nil { models[name] = a }
            case .failure(let e):
                logMissingOnce("model-error:" + name, "failed to load \(name).glb: \(e.localizedDescription)")
            }
        }
    }

    func clearModelCache() {
        models.removeAll()
    }

    // MARK: images / data / audio

    /// Resources/Textures/<name>.png|jpg (cached; nil + one log line when missing)
    func image(_ name: String) -> UIImage? {
        if let hit = images[name] { return hit }
        if missingImages.contains(name) { return nil }
        guard let url = locate(name, extensions: ["png", "jpg", "jpeg"], directory: "Textures"),
              let img = UIImage(contentsOfFile: url.path) else {
            missingImages.insert(name)
            logMissingOnce("image:" + name, "missing texture \(name)")
            return nil
        }
        images[name] = img
        return img
    }

    /// Resources/Data/<name>.json decoded into `type`
    func json<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard let url = locate(name, extensions: ["json"], directory: "Data") else {
            logMissingOnce("json:" + name, "missing data file \(name).json")
            throw AssetError.fileNotFound(name + ".json")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AssetError.unreadable(name + ".json", error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AssetError.decodeFailed(name + ".json", error.localizedDescription)
        }
    }

    /// Resources/Audio/<name>.m4a
    func audioURL(_ name: String) -> URL? {
        if let u = locate(name, extensions: ["m4a", "caf", "wav", "mp3"], directory: "Audio") { return u }
        logMissingOnce("audio:" + name, "missing audio \(name)")
        return nil
    }
}
