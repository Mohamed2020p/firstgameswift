# -*- coding: utf-8 -*-
"""
Static Swift checker (there is no Swift compiler on this Windows machine).

  python tools/check_swift.py [--root Supercars] [--symbols]

1. SYNTAX   parses every .swift file with tree-sitter-swift and reports ERROR / MISSING nodes with line numbers.
2. SYMBOLS  (--symbols) collects every type declared in the project and flags capitalised identifiers that are used as types /
            initialisers but are neither declared in the project nor a known Apple framework symbol (typos, missing files).
3. DUPES    flags top-level types / global functions declared twice (duplicate definitions fail to compile).
4. LINT     a few cheap checks for classic compile errors: unbalanced #if, `self.` misuse cannot be detected - so only obvious ones.
Exit code 1 when problems are found.
"""
import os
import re
import sys

import tree_sitter_swift
from tree_sitter import Language, Parser

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Supercars")
for i, a in enumerate(sys.argv):
    if a == "--root" and i + 1 < len(sys.argv):
        ROOT = os.path.abspath(sys.argv[i + 1])

LANG = Language(tree_sitter_swift.language())
PARSER = Parser(LANG)

# Apple / Swift symbols we legitimately use that start with a capital letter (extended as needed).
APPLE = set("""
Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Float Double CGFloat Bool String Character Array Dictionary Set Optional Data Date URL UUID Result Void Any AnyObject Error
Codable Encodable Decodable Equatable Hashable Identifiable CaseIterable Comparable Sendable RawRepresentable Sequence Collection
SIMD2 SIMD3 SIMD4 simd_float3 simd_float4 simd_float4x4 simd_float3x3 simd_quatf matrix_float4x4 simd_float2
Foundation NSObject NSNumber NSValue NSString NSDictionary NSArray NSCoder NSLock NSNull NSError NSRange NSCache NSDate NSMutableData NSAttributedString
UIKit UIColor UIImage UIView UIViewController UIApplication UIApplicationDelegate UIResponder UIWindow UIScreen UIDevice UIBezierPath UIFont UIGraphicsImageRenderer UIGraphicsImageRendererFormat UIGraphicsBeginImageContextWithOptions UIInterfaceOrientation UIInterfaceOrientationMask UIStatusBarStyle UIUserInterfaceStyle UIImpactFeedbackGenerator UINotificationFeedbackGenerator UISelectionFeedbackGenerator UIPanGestureRecognizer UITapGestureRecognizer UILongPressGestureRecognizer UIPinchGestureRecognizer UIGestureRecognizer UITouch UIEvent UIRectCorner UILabel UIStackView UIHostingController UIScene UISceneSession UISceneConfiguration UIWindowScene UIWindowSceneDelegate UIActivityIndicatorView UIButton UITextField UISlider UISwitch UIVisualEffectView UIBlurEffect UIImageView UILayoutGuide UIEdgeInsets UIOffset UIGestureRecognizerDelegate UIGestureRecognizerState UIRectEdge UIContentSizeCategory UIPasteboard UIControl UIViewAutoresizing
SceneKit SCNScene SCNNode SCNView SCNCamera SCNLight SCNGeometry SCNGeometrySource SCNGeometryElement SCNGeometryPrimitiveType SCNMaterial SCNMaterialProperty SCNBox SCNSphere SCNPlane SCNCylinder SCNCone SCNCapsule SCNTorus SCNTube SCNPyramid SCNFloor SCNText SCNShape SCNParticleSystem SCNAction SCNTransaction SCNVector3 SCNVector4 SCNMatrix4 SCNQuaternion SCNSkinner SCNMorpher SCNLevelOfDetail SCNHitTestResult SCNPhysicsBody SCNPhysicsShape SCNPhysicsWorld SCNPhysicsContact SCNAudioSource SCNAudioPlayer SCNReferenceNode SCNConstraint SCNLookAtConstraint SCNBillboardConstraint SCNTransformConstraint SCNIKConstraint SCNAnimationEvent SCNAnimation SCNAnimationPlayer SCNSceneRenderer SCNSceneRendererDelegate SCNProgram SCNShadable SCNTechnique SCNFilterable SCNBoundingVolume SCNAnimatable SCNAnimationTimingFunction SCNLightingModel SCNTessellator SCNRenderer SCNSceneSource SCNCullMode SCNBlendMode SCNTransparencyMode SCNLightType SCNShadowMode SCNBillboardAxis SCNAntialiasingMode SCNParticleBirthLocation SCNParticleBlendMode SCNParticleImageSequenceAnimationMode SCNParticleSortingMode SCNParticleEvent SCNParticleModifierStage SCNParticleProperty SCNParticleBirthDirection SCNParticleOrientationMode SCNParticleInputMode SCNParticleInteractionMode SCNParticleCollisionMode SCNParticlePropertyController SCNParticleEventBlock SCNParticleModifierBlock SCNFillMode SCNColorMask SCNMovabilityHint SCNCameraController SCNInteractionMode SCNNodeRendererDelegate SCNCameraProjectionDirection SCNWrapMode SCNFilterMode SCNChamferMode SCNAnimationEvent SCNPhysicsField SCNPhysicsBehavior SCNNodeFocusBehavior
Metal MTLDevice MTLBuffer MTLTexture MTLCreateSystemDefaultDevice MTLStorageMode MTLResourceOptions MTLPixelFormat
ModelIO MDLAsset MDLMesh MDLTexture MDLMaterial
SwiftUI View Text Image Button VStack HStack ZStack Spacer Color Font Slider Toggle Picker Form List ScrollView LazyVGrid LazyHGrid LazyVStack LazyHStack GridItem Section Group Divider Circle Rectangle RoundedRectangle Capsule Path Shape ForEach GeometryReader Binding State StateObject ObservedObject EnvironmentObject Environment AppStorage Published Canvas TimelineView DragGesture TapGesture LongPressGesture MagnificationGesture RotationGesture SimultaneousGesture ExclusiveGesture SequenceGesture Gesture Animation Angle AngularGradient LinearGradient RadialGradient Gradient GraphicsContext CGSize CGPoint CGRect CGVector CGAffineTransform CGColor CGContext CGImage CGColorSpace CGGradient CGPath CGMutablePath CGLineCap CGLineJoin CGBlendMode CGFloat NavigationStack NavigationView NavigationLink TabView Menu Label Stepper ProgressView Alert ViewModifier UnitPoint Edge EdgeInsets Alignment HorizontalAlignment VerticalAlignment TextField SecureField DisclosureGroup ColorPicker Link Sheet AnyView EmptyView TupleView Transaction Namespace PreferenceKey SceneStorage ViewBuilder ButtonStyle PrimitiveButtonStyle LabelStyle ToggleStyle FocusState AnyTransition Material ContentSizeCategory ColorScheme ScenePhase Visibility Axis TextAlignment FontWeight Font LineStyle StrokeStyle StrokeStyle FillStyle StrokeStyle Anchor GridItem SwiftUI ContainerRelativeShape UnevenRoundedRectangle Ellipse OffsetShape ScaledShape RotatedShape ViewThatFits PopoverAttachmentAnchor PresentationDetent
Combine AnyCancellable PassthroughSubject CurrentValueSubject Publisher Subscriber Subscribers Just ObservableObject Cancellable ObservableObjectPublisher
AVFoundation AVAudioEngine AVAudioPlayerNode AVAudioMixerNode AVAudioUnitVarispeed AVAudioUnitTimePitch AVAudioUnitEQ AVAudioUnitReverb AVAudioUnitDelay AVAudioUnitDistortion AVAudioEnvironmentNode AVAudioSession AVAudioFile AVAudioPCMBuffer AVAudioFormat AVAudioTime AVAudioNode AVAudioMixing AVAudio3DPoint AVAudio3DAngularOrientation AVAudio3DMixingRenderingAlgorithm AVAudioEnvironmentDistanceAttenuationParameters AVAudioEnvironmentReverbParameters AVAudioBuffer AVAudioConnectionPoint AVAudioUnit AVAudioUnitEffect AVAudioUnitGenerator AVAudioUnitSampler AVAudioSessionCategory AVAudioSessionMode AVAudioSessionCategoryOptions AVAudioPlayer AVAudioRecorder AVAudioChannelLayout AVAudioCommonFormat AVAudioApplication AVAudioSinkNode AVAudioSourceNode AVAudioIONode AVAudioInputNode AVAudioOutputNode AVAudioEngineManualRenderingMode AVPlayer AVPlayerItem AVAsset AVURLAsset AVAudioUnitTimeEffect AVAudioUnitMIDIInstrument AVAudioSequencer AVMIDIPlayer AVSpeechSynthesizer
CoreMotion CMMotionManager CMDeviceMotion CMAttitude CMAccelerometerData CMGyroData CMAcceleration CMRotationRate CMAttitudeReferenceFrame CMHeadphoneMotionManager
GameController GCController GCExtendedGamepad GCControllerButtonInput GCControllerDirectionPad GCControllerAxisInput GCMicroGamepad GCKeyboard GCKeyboardInput GCMouse GCMouseInput GCInputButtonA GCInputButtonB GCInputButtonX GCInputButtonY GCInputLeftShoulder GCInputRightShoulder GCInputLeftTrigger GCInputRightTrigger GCInputLeftThumbstickButton GCInputRightThumbstickButton GCInputDirectionPad GCInputLeftThumbstick GCInputRightThumbstick GCInputButtonMenu GCInputButtonOptions GCDevicePhysicalInput GCPhysicalInputProfile GCControllerElement GCDevice GCKeyCode GCButtonElementName GCDirectionPadElementName
CoreHaptics CHHapticEngine CHHapticEvent CHHapticPattern CHHapticEventParameter
CoreGraphics CoreImage CIContext CIImage CIFilter CIColor CIVector CIKernel
QuartzCore CADisplayLink CALayer CAShapeLayer CAGradientLayer CATransaction CABasicAnimation CAKeyframeAnimation CAMediaTimingFunction CATextLayer CAMetalLayer CAEmitterLayer CAAnimation CAAnimationGroup CATransform3D CATransform3DIdentity CAFrameRateRange CAMediaTiming CAAction CAReplicatorLayer CAScrollLayer CATiledLayer CATransformLayer CAEAGLLayer CARenderer CAValueFunction CAConstraint CALayerContentsFilter
Dispatch DispatchQueue DispatchWorkItem DispatchTime DispatchGroup DispatchSemaphore DispatchTimeInterval DispatchQoS DispatchSource DispatchData DispatchIO
Task MainActor Actor TaskGroup CheckedContinuation UnsafeContinuation AsyncStream AsyncThrowingStream AsyncSequence AsyncIteratorProtocol TaskPriority Continuation
JSONDecoder JSONEncoder PropertyListDecoder PropertyListEncoder JSONSerialization PropertyListSerialization CodingKeys CodingKey DecodingError EncodingError KeyedDecodingContainer KeyedEncodingContainer UnkeyedDecodingContainer SingleValueDecodingContainer
FileManager FileHandle Bundle ProcessInfo Thread Timer RunLoop Operation OperationQueue NotificationCenter Notification NSNotification UserDefaults Calendar DateFormatter DateComponents TimeInterval TimeZone Locale Measurement Unit UnitLength UnitSpeed NumberFormatter ByteCountFormatter Scanner CharacterSet IndexSet IndexPath ObjCBool OSLog Logger os_log OSAllocatedUnfairLock os_unfair_lock
Bundle Mirror Never Range ClosedRange PartialRangeFrom PartialRangeThrough PartialRangeUpTo Slice ArraySlice ContiguousArray UnsafePointer UnsafeMutablePointer UnsafeRawPointer UnsafeMutableRawPointer UnsafeBufferPointer UnsafeMutableBufferPointer UnsafeRawBufferPointer UnsafeMutableRawBufferPointer OpaquePointer Unmanaged ManagedBuffer AutoreleasingUnsafeMutablePointer
Self Type Protocol Any Decimal Duration ContinuousClock SuspendingClock Instant Clock
ObjectIdentifier Hasher LosslessStringConvertible CustomStringConvertible CustomDebugStringConvertible TextOutputStream TextOutputStreamable OptionSet SetAlgebra BinaryInteger FixedWidthInteger SignedInteger UnsignedInteger BinaryFloatingPoint FloatingPoint Numeric AdditiveArithmetic SignedNumeric Strideable ExpressibleByStringLiteral ExpressibleByArrayLiteral ExpressibleByDictionaryLiteral ExpressibleByIntegerLiteral ExpressibleByFloatLiteral ExpressibleByBooleanLiteral ExpressibleByNilLiteral IteratorProtocol BidirectionalCollection RandomAccessCollection MutableCollection RangeReplaceableCollection LazySequenceProtocol RandomNumberGenerator SystemRandomNumberGenerator EnumeratedSequence Zip2Sequence DefaultIndices
UIAccessibility ProcessInfo ThermalState StoreKit
""".split())

TYPE_DECL_KINDS = ("class_declaration", "protocol_declaration", "typealias_declaration")


def walk(node):
    stack = [node]
    while stack:
        n = stack.pop()
        yield n
        stack.extend(reversed(n.children))


def find_errors(tree, src):
    out = []
    for n in walk(tree.root_node):
        if n.type == "ERROR" or n.is_missing:
            line = n.start_point[0] + 1
            text = src[n.start_byte:n.end_byte].decode("utf8", "replace")[:80].replace("\n", " ")
            out.append((line, ("MISSING " + n.type) if n.is_missing else "ERROR", text))
    return out


def declared_names(tree, src):
    """type-like declarations (class/struct/enum/actor/extension excluded) + typealiases + top-level funcs"""
    types, funcs = [], []
    for n in walk(tree.root_node):
        if n.type == "class_declaration":
            nm = n.child_by_field_name("name")
            kind_tok = next((c.type for c in n.children if c.type in ("struct", "class", "enum", "actor", "extension")), None)
            if nm is not None and kind_tok != "extension":
                types.append((src[nm.start_byte:nm.end_byte].decode(), n.start_point[0] + 1, n.parent.type == "source_file"))
        elif n.type in ("protocol_declaration", "typealias_declaration"):
            nm = n.child_by_field_name("name")
            if nm is not None:
                types.append((src[nm.start_byte:nm.end_byte].decode(), n.start_point[0] + 1, n.parent.type == "source_file"))
        elif n.type == "function_declaration" and n.parent.type == "source_file":
            nm = n.child_by_field_name("name")
            if nm is not None:
                funcs.append((src[nm.start_byte:nm.end_byte].decode(), n.start_point[0] + 1))
    return types, funcs


def used_type_names(tree, src):
    """capitalised identifiers used as types or initialisers (Foo(...), : Foo, as Foo, Foo.bar)"""
    used = {}
    for n in walk(tree.root_node):
        if n.type in ("type_identifier", "simple_identifier"):
            t = src[n.start_byte:n.end_byte].decode()
            if t and t[0].isupper() and not t.isupper():
                used.setdefault(t, n.start_point[0] + 1)
    return used


def enum_cases(tree, src):
    """names of enum cases (they are lowercase normally, but ignore capitalised ones that are cases)"""
    cases = set()
    for n in walk(tree.root_node):
        if n.type == "enum_entry":
            for c in n.children:
                if c.type == "simple_identifier":
                    cases.add(src[c.start_byte:c.end_byte].decode())
    return cases


def main():
    files = []
    for dp, dn, fn in os.walk(ROOT):
        for f in fn:
            if f.endswith(".swift"):
                files.append(os.path.join(dp, f))
    files.sort()
    problems = 0
    parsed = {}
    for f in files:
        src = open(f, "rb").read()
        tree = PARSER.parse(src)
        parsed[f] = (tree, src)
        errs = find_errors(tree, src)
        rel = os.path.relpath(f, ROOT)
        if errs:
            problems += len(errs)
            for line, kind, text in errs[:12]:
                print("SYNTAX %s:%d %s near: %s" % (rel, line, kind, text))
            if len(errs) > 12:
                print("SYNTAX %s: … %d more" % (rel, len(errs) - 12))
        # balance of #if / #endif
        s = src.decode("utf8", "replace")
        if len(re.findall(r"^\s*#if\b", s, re.M)) != len(re.findall(r"^\s*#endif\b", s, re.M)):
            print("LINT   %s: unbalanced #if/#endif" % rel)
            problems += 1
    print("parsed %d swift files, %d syntax problems" % (len(files), problems))
    if "--symbols" in sys.argv:
        all_types = {}
        top_funcs = {}
        cases = set()
        for f, (tree, src) in parsed.items():
            rel = os.path.relpath(f, ROOT)
            types, funcs = declared_names(tree, src)
            cases |= enum_cases(tree, src)
            for name, line, top in types:
                if top:
                    if name in all_types:
                        print("DUPE   type %s declared in %s:%d and %s" % (name, rel, line, all_types[name]))
                        problems += 1
                    all_types[name] = "%s:%d" % (rel, line)
                else:
                    all_types.setdefault(name, "%s:%d" % (rel, line))
            for name, line in funcs:
                if name in top_funcs:
                    print("DUPE   func %s declared in %s:%d and %s" % (name, rel, line, top_funcs[name]))
                    problems += 1
                top_funcs[name] = "%s:%d" % (rel, line)
        unknown = {}
        for f, (tree, src) in parsed.items():
            rel = os.path.relpath(f, ROOT)
            for name, line in used_type_names(tree, src).items():
                if name in all_types or name in APPLE or name in cases:
                    continue
                unknown.setdefault(name, []).append("%s:%d" % (rel, line))
        for name, where in sorted(unknown.items()):
            print("UNKNOWN symbol %-28s used at %s%s" % (name, ", ".join(where[:3]), " …" if len(where) > 3 else ""))
        print("%d project types, %d unknown capitalised symbols (review each: typo, missing file, or extend APPLE list)" % (len(all_types), len(unknown)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
