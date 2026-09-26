import Foundation
import simd

// MARK: - glTF 2.0 binary (.glb) container, JSON schema subset and accessor decoding.
// tools/check_glb_reader.py is a line-by-line Python mirror of the rules implemented here (validated on the real input files).

/// Subset of the glTF 2.0 JSON schema we need. Unknown keys (extras, unknown extensions, animations, cameras ...) are ignored by Decodable.
enum GLBSchema {
    struct Root: Decodable {
        var extensionsUsed: [String]?
        var extensionsRequired: [String]?
        var scene: Int?
        var scenes: [Scene]?
        var nodes: [Node]?
        var meshes: [Mesh]?
        var materials: [Material]?
        var textures: [Texture]?
        var images: [Image]?
        var samplers: [Sampler]?
        var accessors: [Accessor]?
        var bufferViews: [BufferView]?
        var buffers: [Buffer]?
        var skins: [Skin]?
    }

    struct Scene: Decodable {
        var name: String?
        var nodes: [Int]?
    }

    struct Node: Decodable {
        var name: String?
        var children: [Int]?
        var mesh: Int?
        var skin: Int?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
    }

    struct Mesh: Decodable {
        var name: String?
        var primitives: [Primitive]
    }

    struct Primitive: Decodable {
        var attributes: [String: Int]
        var indices: Int?
        var material: Int?
        var mode: Int?
    }

    struct TextureInfo: Decodable {
        var index: Int
        var texCoord: Int?
    }

    struct NormalTextureInfo: Decodable {
        var index: Int
        var texCoord: Int?
        var scale: Float?
    }

    struct OcclusionTextureInfo: Decodable {
        var index: Int
        var texCoord: Int?
        var strength: Float?
    }

    struct PBR: Decodable {
        var baseColorFactor: [Float]?
        var baseColorTexture: TextureInfo?
        var metallicFactor: Float?
        var roughnessFactor: Float?
        var metallicRoughnessTexture: TextureInfo?
    }

    struct EmissiveStrength: Decodable {
        var emissiveStrength: Float?
    }

    struct MaterialExtensions: Decodable {
        var KHR_materials_emissive_strength: EmissiveStrength?
    }

    struct Material: Decodable {
        var name: String?
        var pbrMetallicRoughness: PBR?
        var normalTexture: NormalTextureInfo?
        var occlusionTexture: OcclusionTextureInfo?
        var emissiveTexture: TextureInfo?
        var emissiveFactor: [Float]?
        var alphaMode: String?
        var alphaCutoff: Float?
        var doubleSided: Bool?
        var extensions: MaterialExtensions?
    }

    struct Texture: Decodable {
        var sampler: Int?
        var source: Int?
        var name: String?
    }

    struct Image: Decodable {
        var uri: String?
        var mimeType: String?
        var bufferView: Int?
        var name: String?
    }

    struct Sampler: Decodable {
        var magFilter: Int?
        var minFilter: Int?
        var wrapS: Int?
        var wrapT: Int?
    }

    struct SparseMarker: Decodable {
        var count: Int?
    }

    struct Accessor: Decodable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
        var sparse: SparseMarker?
    }

    struct BufferView: Decodable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
    }

    struct Buffer: Decodable {
        var byteLength: Int
        var uri: String?
    }

    struct Skin: Decodable {
        var name: String?
        var joints: [Int]
        var skeleton: Int?
        var inverseBindMatrices: Int?
    }
}

/// Where the elements of one accessor live inside a Data blob.
struct GLBAccessorSpan {
    let data: Data
    let start: Int          // absolute byte offset of element 0 inside `data`
    let stride: Int         // byte distance between two elements (bufferView.byteStride, else the packed element size)
    let count: Int
    let components: Int
    let componentType: Int  // 5120 i8, 5121 u8, 5122 i16, 5123 u16, 5125 u32, 5126 f32
    let normalized: Bool
    let hasData: Bool       // false: accessor without bufferView => all zeros
}

/// The parsed container: JSON + binary chunk, and all typed reads from it.
final class GLBBinaryStore {
    let fileName: String
    let root: GLBSchema.Root
    private let fileData: Data
    private let binOffset: Int
    private let binLength: Int
    private let baseDirectory: URL?
    private var externalBuffers: [Int: Data] = [:]

    // MARK: container

    private static func readU32(_ d: Data, _ o: Int) -> UInt32 {
        let b0: UInt32 = UInt32(d[d.startIndex + o])
        let b1: UInt32 = UInt32(d[d.startIndex + o + 1])
        let b2: UInt32 = UInt32(d[d.startIndex + o + 2])
        let b3: UInt32 = UInt32(d[d.startIndex + o + 3])
        var v: UInt32 = b0
        v |= (b1 << 8)
        v |= (b2 << 16)
        v |= (b3 << 24)
        return v
    }

    /// Parses a complete .glb file. `directory` is used to resolve external buffer/image URIs (rare in GLB files).
    init(fileData: Data, fileName: String, directory: URL?) throws {
        self.fileName = fileName
        self.fileData = fileData
        self.baseDirectory = directory
        let total: Int = fileData.count
        if total < 20 { throw AssetError.malformed(fileName, "file is smaller than a GLB header") }
        let magic: UInt32 = GLBBinaryStore.readU32(fileData, 0)
        if magic != 0x4654_6C67 { throw AssetError.malformed(fileName, "not a GLB file (bad magic)") }
        let version: UInt32 = GLBBinaryStore.readU32(fileData, 4)
        if version != 2 { throw AssetError.unsupported(fileName, "glTF version \(version) (only 2.0)") }
        var declared: Int = Int(GLBBinaryStore.readU32(fileData, 8))
        if declared > total || declared < 20 { declared = total }

        var jsonRange: Range<Int>? = nil
        var bo: Int = 0
        var bl: Int = 0
        var haveBin: Bool = false
        var offset: Int = 12
        while offset + 8 <= declared {
            let chunkLength: Int = Int(GLBBinaryStore.readU32(fileData, offset))
            let chunkType: UInt32 = GLBBinaryStore.readU32(fileData, offset + 4)
            let bodyStart: Int = offset + 8
            if bodyStart + chunkLength > total { throw AssetError.malformed(fileName, "chunk overruns the file") }
            if chunkType == 0x4E4F_534A && jsonRange == nil {
                jsonRange = bodyStart..<(bodyStart + chunkLength)
            } else if chunkType == 0x004E_4942 && !haveBin {
                bo = bodyStart
                bl = chunkLength
                haveBin = true
            }
            offset = bodyStart + chunkLength
            offset = (offset + 3) & ~3
        }
        guard let jr = jsonRange else { throw AssetError.malformed(fileName, "no JSON chunk") }
        binOffset = bo
        binLength = bl
        let jsonData: Data = fileData.subdata(in: (fileData.startIndex + jr.lowerBound)..<(fileData.startIndex + jr.upperBound))
        do {
            root = try JSONDecoder().decode(GLBSchema.Root.self, from: jsonData)
        } catch {
            throw AssetError.malformed(fileName, "invalid glTF JSON: \(error.localizedDescription)")
        }
        let required: [String] = root.extensionsRequired ?? []
        let unsupported: Set<String> = ["KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_texture_basisu"]
        for r in required where unsupported.contains(r) {
            throw AssetError.unsupported(fileName, "required extension \(r)")
        }
    }

    // MARK: buffers

    private func bufferSpan(_ index: Int) throws -> (data: Data, offset: Int, length: Int) {
        let buffers: [GLBSchema.Buffer] = root.buffers ?? []
        if index < 0 || index >= buffers.count { throw AssetError.malformed(fileName, "buffer \(index) does not exist") }
        let b: GLBSchema.Buffer = buffers[index]
        guard let uri = b.uri else {
            if index != 0 || binLength == 0 { throw AssetError.malformed(fileName, "buffer \(index) has no uri and there is no BIN chunk") }
            return (fileData, binOffset, binLength)
        }
        if let cached = externalBuffers[index] { return (cached, 0, cached.count) }
        var loaded: Data? = nil
        if uri.hasPrefix("data:") {
            if let comma = uri.firstIndex(of: ",") {
                let payload: String = String(uri[uri.index(after: comma)...])
                loaded = Data(base64Encoded: payload)
            }
        } else if let dir = baseDirectory {
            let decoded: String = uri.removingPercentEncoding ?? uri
            loaded = try? Data(contentsOf: dir.appendingPathComponent(decoded))
        }
        guard let d = loaded else { throw AssetError.malformed(fileName, "cannot load buffer uri \(uri.prefix(40))") }
        externalBuffers[index] = d
        return (d, 0, d.count)
    }

    /// Raw bytes of a bufferView (used for embedded images).
    func bufferViewData(_ index: Int) throws -> Data {
        let views: [GLBSchema.BufferView] = root.bufferViews ?? []
        if index < 0 || index >= views.count { throw AssetError.malformed(fileName, "bufferView \(index) does not exist") }
        let bv: GLBSchema.BufferView = views[index]
        let span = try bufferSpan(bv.buffer)
        let start: Int = span.offset + (bv.byteOffset ?? 0)
        let end: Int = start + bv.byteLength
        if bv.byteLength < 0 || end > span.offset + span.length || end > span.data.count {
            throw AssetError.malformed(fileName, "bufferView \(index) exceeds its buffer")
        }
        return span.data.subdata(in: (span.data.startIndex + start)..<(span.data.startIndex + end))
    }

    /// Data of an external / data-URI image (nil when the image uses a bufferView).
    func imageURIData(_ image: GLBSchema.Image) -> Data? {
        guard let uri = image.uri else { return nil }
        if uri.hasPrefix("data:") {
            if let comma = uri.firstIndex(of: ",") {
                return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            }
            return nil
        }
        if let dir = baseDirectory {
            let decoded: String = uri.removingPercentEncoding ?? uri
            return try? Data(contentsOf: dir.appendingPathComponent(decoded))
        }
        return nil
    }

    // MARK: accessors

    static func componentCount(of type: String) -> Int? {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT4": return 16
        default: return nil
        }
    }

    static func componentSize(of componentType: Int) -> Int? {
        switch componentType {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return nil
        }
    }

    func accessorCount(_ index: Int) throws -> Int {
        let accessors: [GLBSchema.Accessor] = root.accessors ?? []
        if index < 0 || index >= accessors.count { throw AssetError.malformed(fileName, "accessor \(index) does not exist") }
        return accessors[index].count
    }

    func accessorType(_ index: Int) throws -> String {
        let accessors: [GLBSchema.Accessor] = root.accessors ?? []
        if index < 0 || index >= accessors.count { throw AssetError.malformed(fileName, "accessor \(index) does not exist") }
        return accessors[index].type
    }

    /// Rules (mirrored in tools/check_glb_reader.py): base = bufferView.byteOffset + accessor.byteOffset ; element size = components * componentSize ;
    /// stride = bufferView.byteStride if > 0 else element size ; element i starts at base + i * stride ; every element must lie inside the bufferView.
    func span(accessor index: Int) throws -> GLBAccessorSpan {
        let accessors: [GLBSchema.Accessor] = root.accessors ?? []
        if index < 0 || index >= accessors.count { throw AssetError.malformed(fileName, "accessor \(index) does not exist") }
        let a: GLBSchema.Accessor = accessors[index]
        guard let comps = GLBBinaryStore.componentCount(of: a.type) else {
            throw AssetError.unsupported(fileName, "accessor type \(a.type)")
        }
        guard let csize = GLBBinaryStore.componentSize(of: a.componentType) else {
            throw AssetError.malformed(fileName, "accessor \(index) has componentType \(a.componentType)")
        }
        if a.count < 0 { throw AssetError.malformed(fileName, "accessor \(index) negative count") }
        let normalized: Bool = a.normalized ?? false
        guard let viewIndex = a.bufferView else {
            return GLBAccessorSpan(data: Data(), start: 0, stride: comps * csize, count: a.count, components: comps,
                                   componentType: a.componentType, normalized: normalized, hasData: false)
        }
        let views: [GLBSchema.BufferView] = root.bufferViews ?? []
        if viewIndex < 0 || viewIndex >= views.count { throw AssetError.malformed(fileName, "accessor \(index): bufferView \(viewIndex) does not exist") }
        let bv: GLBSchema.BufferView = views[viewIndex]
        let buf = try bufferSpan(bv.buffer)
        let viewStart: Int = buf.offset + (bv.byteOffset ?? 0)
        let viewEnd: Int = viewStart + bv.byteLength
        if viewEnd > buf.offset + buf.length || viewEnd > buf.data.count {
            throw AssetError.malformed(fileName, "bufferView \(viewIndex) exceeds its buffer")
        }
        let elementSize: Int = comps * csize
        let declaredStride: Int = bv.byteStride ?? 0
        let stride: Int = declaredStride > 0 ? declaredStride : elementSize
        if stride < elementSize { throw AssetError.malformed(fileName, "accessor \(index): stride \(stride) < element size \(elementSize)") }
        let start: Int = viewStart + (a.byteOffset ?? 0)
        if a.count > 0 {
            let last: Int = start + (a.count - 1) * stride + elementSize
            if last > viewEnd { throw AssetError.malformed(fileName, "accessor \(index) overruns bufferView \(viewIndex)") }
        }
        return GLBAccessorSpan(data: buf.data, start: start, stride: stride, count: a.count, components: comps,
                               componentType: a.componentType, normalized: normalized, hasData: true)
    }

    // MARK: typed reads

    @inline(__always)
    private static func readFloat(_ p: UnsafeRawPointer, _ componentType: Int, _ normalized: Bool) -> Float {
        switch componentType {
        case 5126:
            var bits: UInt32 = 0
            memcpy(&bits, p, 4)
            return Float(bitPattern: bits)
        case 5121:
            let v: UInt8 = p.load(as: UInt8.self)
            return normalized ? Float(v) / 255.0 : Float(v)
        case 5123:
            var v: UInt16 = 0
            memcpy(&v, p, 2)
            return normalized ? Float(v) / 65535.0 : Float(v)
        case 5125:
            var v: UInt32 = 0
            memcpy(&v, p, 4)
            return Float(v)
        case 5120:
            let v: Int8 = p.load(as: Int8.self)
            let f: Float = Float(v)
            return normalized ? max(f / 127.0, -1.0) : f
        default: // 5122
            var v: Int16 = 0
            memcpy(&v, p, 2)
            let f: Float = Float(v)
            return normalized ? max(f / 32767.0, -1.0) : f
        }
    }

    @inline(__always)
    private static func readUInt(_ p: UnsafeRawPointer, _ componentType: Int) -> UInt32 {
        switch componentType {
        case 5121:
            return UInt32(p.load(as: UInt8.self))
        case 5123:
            var v: UInt16 = 0
            memcpy(&v, p, 2)
            return UInt32(v)
        case 5125:
            var v: UInt32 = 0
            memcpy(&v, p, 4)
            return v
        case 5126:
            var bits: UInt32 = 0
            memcpy(&bits, p, 4)
            let f: Float = Float(bitPattern: bits)
            return f > 0 ? UInt32(f) : 0
        case 5120:
            let v: Int8 = p.load(as: Int8.self)
            return v > 0 ? UInt32(v) : 0
        default: // 5122
            var v: Int16 = 0
            memcpy(&v, p, 2)
            return v > 0 ? UInt32(v) : 0
        }
    }

    /// All components of an accessor as Float (count * components values, element-major). Normalised integers are converted to [0,1] / [-1,1].
    func floats(accessor index: Int) throws -> [Float] {
        let s: GLBAccessorSpan = try span(accessor: index)
        let total: Int = s.count * s.components
        var out: [Float] = [Float](repeating: 0, count: total)
        if !s.hasData || total == 0 { return out }
        let csize: Int = GLBBinaryStore.componentSize(of: s.componentType) ?? 4
        let packed: Bool = s.componentType == 5126 && s.stride == s.components * 4
        s.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            out.withUnsafeMutableBufferPointer { (dst: inout UnsafeMutableBufferPointer<Float>) -> Void in
                guard let dstBase = dst.baseAddress else { return }
                if packed {
                    memcpy(dstBase, base + s.start, total * 4)
                    return
                }
                for i in 0..<s.count {
                    let row: UnsafeRawPointer = base + s.start + i * s.stride
                    for c in 0..<s.components {
                        dstBase[i * s.components + c] = GLBBinaryStore.readFloat(row + c * csize, s.componentType, s.normalized)
                    }
                }
            }
        }
        return out
    }

    /// All components of an integer accessor as UInt32 (indices, joints).
    func uints(accessor index: Int) throws -> [UInt32] {
        let s: GLBAccessorSpan = try span(accessor: index)
        let total: Int = s.count * s.components
        var out: [UInt32] = [UInt32](repeating: 0, count: total)
        if !s.hasData || total == 0 { return out }
        let csize: Int = GLBBinaryStore.componentSize(of: s.componentType) ?? 4
        s.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            out.withUnsafeMutableBufferPointer { (dst: inout UnsafeMutableBufferPointer<UInt32>) -> Void in
                guard let dstBase = dst.baseAddress else { return }
                for i in 0..<s.count {
                    let row: UnsafeRawPointer = base + s.start + i * s.stride
                    for c in 0..<s.components {
                        dstBase[i * s.components + c] = GLBBinaryStore.readUInt(row + c * csize, s.componentType)
                    }
                }
            }
        }
        return out
    }
}
