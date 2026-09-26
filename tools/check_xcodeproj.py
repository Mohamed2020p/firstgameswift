# -*- coding: utf-8 -*-
"""
Independent validator for Supercars.xcodeproj (does NOT import gen_xcodeproj.py).

    python tools/check_xcodeproj.py

Parses project.pbxproj with its own small OpenStep-plist parser and verifies:
  * syntax, unique object ids, rootObject / mainGroup / target / product / config lists exist
  * every referenced object id exists and has the expected isa
  * every PBXFileReference resolves to a path that exists on disk (SDKROOT / BUILT_PRODUCTS_DIR ones are skipped)
  * every .swift under Supercars/ (except Resources/) is in the Sources phase exactly once, and nothing else is
  * Assets.xcassets + Models/Textures/Data/Audio folder references are in the Resources phase, Info.plist is in none
  * Frameworks phase contents; Debug + Release configs for project and target; key build settings
  * the shared scheme references the target id / container; workspace file exists
  * Info.plist parses, asset catalog JSON parses, AppIcon.png is 1024x1024 RGB; project.yml (if PyYAML present) agrees on frameworks
Exit code 1 on any problem.
"""
import json
import os
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROJ = os.path.join(ROOT, "Supercars.xcodeproj")
PBX = os.path.join(PROJ, "project.pbxproj")

problems = []
warnings = []


def fail(msg):
    problems.append(msg)


# ---------------------------------------------------------------------------- OpenStep parser
class ParseError(Exception):
    pass


class Parser:
    def __init__(self, text):
        self.t = text
        self.i = 0
        self.n = len(text)
        self.dupes = []

    def skip(self):
        t = self.t
        while self.i < self.n:
            c = t[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif t.startswith("/*", self.i):
                j = t.find("*/", self.i + 2)
                if j < 0:
                    raise ParseError("unterminated comment")
                self.i = j + 2
            elif t.startswith("//", self.i):
                j = t.find("\n", self.i)
                self.i = self.n if j < 0 else j + 1
            else:
                break

    def parse_value(self):
        self.skip()
        if self.i >= self.n:
            raise ParseError("unexpected end")
        c = self.t[self.i]
        if c == "{":
            return self.parse_dict()
        if c == "(":
            return self.parse_array()
        if c == '"':
            return self.parse_quoted()
        return self.parse_bare()

    def parse_dict(self):
        self.i += 1
        d = {}
        while True:
            self.skip()
            if self.i >= self.n:
                raise ParseError("unterminated dict")
            if self.t[self.i] == "}":
                self.i += 1
                return d
            key = self.parse_value()
            if not isinstance(key, str):
                raise ParseError("dict key is not a string at %d" % self.i)
            self.skip()
            if self.t[self.i] != "=":
                raise ParseError("expected '=' after key %r at offset %d" % (key, self.i))
            self.i += 1
            val = self.parse_value()
            self.skip()
            if self.t[self.i] != ";":
                raise ParseError("expected ';' after value of %r at offset %d" % (key, self.i))
            self.i += 1
            if key in d:
                self.dupes.append(key)
            d[key] = val

    def parse_array(self):
        self.i += 1
        a = []
        while True:
            self.skip()
            if self.i >= self.n:
                raise ParseError("unterminated array")
            c = self.t[self.i]
            if c == ")":
                self.i += 1
                return a
            a.append(self.parse_value())
            self.skip()
            if self.t[self.i] == ",":
                self.i += 1
            elif self.t[self.i] != ")":
                raise ParseError("expected ',' or ')' at offset %d" % self.i)

    def parse_quoted(self):
        self.i += 1
        out = []
        while self.i < self.n:
            c = self.t[self.i]
            if c == "\\":
                nxt = self.t[self.i + 1]
                out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
                self.i += 2
                continue
            if c == '"':
                self.i += 1
                return "".join(out)
            out.append(c)
            self.i += 1
        raise ParseError("unterminated string")

    def parse_bare(self):
        m = re.compile(r"[A-Za-z0-9_$/.:\-]+").match(self.t, self.i)
        if not m:
            raise ParseError("unexpected character %r at offset %d" % (self.t[self.i], self.i))
        self.i = m.end()
        return m.group(0)


def parse_pbx(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if not text.startswith("// !$*UTF8*$!"):
        fail("pbxproj: missing '// !$*UTF8*$!' header")
    p = Parser(text)
    root = p.parse_value()
    p.skip()
    if p.i != p.n:
        fail("pbxproj: trailing garbage after the root dictionary")
    if p.dupes:
        fail("pbxproj: duplicate dictionary keys: %s" % sorted(set(p.dupes))[:10])
    return root


# ---------------------------------------------------------------------------- checks
ID_RE = re.compile(r"^[0-9A-F]{24}$")


def main():
    if not os.path.exists(PBX):
        print("missing", PBX)
        return 1
    try:
        root = parse_pbx(PBX)
    except ParseError as e:
        print("PARSE ERROR:", e)
        return 1

    for k in ("archiveVersion", "objectVersion", "objects", "rootObject", "classes"):
        if k not in root:
            fail("pbxproj: missing top-level key %s" % k)
    objs = root.get("objects", {})
    for oid_ in objs:
        if not ID_RE.match(oid_):
            fail("object id is not 24 upper-case hex digits: %s" % oid_)

    def get(oid_, isa=None, ctx=""):
        o = objs.get(oid_)
        if o is None:
            fail("dangling reference %s (%s)" % (oid_, ctx))
            return None
        if isa and o.get("isa") != isa:
            fail("%s expected isa %s but is %s (%s)" % (oid_, isa, o.get("isa"), ctx))
        return o

    by_isa = {}
    for oid_, o in objs.items():
        by_isa.setdefault(o.get("isa"), []).append(oid_)

    project = get(root.get("rootObject"), "PBXProject", "rootObject")
    if project is None:
        return finish()

    # ---- targets
    targets = project.get("targets", [])
    if len(targets) != 1:
        fail("expected exactly one target, found %d" % len(targets))
    target = get(targets[0], "PBXNativeTarget", "project.targets") if targets else None
    if target is None:
        return finish()
    if target.get("productType") != "com.apple.product-type.application":
        fail("target productType is not application")
    prod = get(target.get("productReference"), "PBXFileReference", "productReference")
    if prod is not None and prod.get("explicitFileType") != "wrapper.application":
        fail("product reference is not wrapper.application")

    # ---- configuration lists
    def check_cfg_list(cl_id, label, required):
        cl = get(cl_id, "XCConfigurationList", label)
        if cl is None:
            return
        names = {}
        for cid in cl.get("buildConfigurations", []):
            c = get(cid, "XCBuildConfiguration", label)
            if c is not None:
                names[c.get("name")] = c.get("buildSettings", {})
        for want in ("Debug", "Release"):
            if want not in names:
                fail("%s: missing %s configuration" % (label, want))
        for cfg, settings in names.items():
            for key, val in required.items():
                if key in settings and settings[key] != val and val is not None:
                    fail("%s/%s: %s = %r, expected %r" % (label, cfg, key, settings[key], val))
                if key not in settings:
                    fail("%s/%s: missing build setting %s" % (label, cfg, key))
        if "Release" in names:
            if names["Release"].get("SWIFT_OPTIMIZATION_LEVEL") != "-O":
                fail("%s/Release: SWIFT_OPTIMIZATION_LEVEL should be -O" % label)
            if names["Release"].get("GCC_OPTIMIZATION_LEVEL") != "s":
                fail("%s/Release: GCC_OPTIMIZATION_LEVEL should be s" % label)

    check_cfg_list(project.get("buildConfigurationList"), "project config list", {
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SWIFT_VERSION": "5.0", "SDKROOT": "iphoneos"})
    check_cfg_list(target.get("buildConfigurationList"), "target config list", {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.c0derz.supercars",
        "INFOPLIST_FILE": "Supercars/Resources/Info.plist",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO", "CODE_SIGN_IDENTITY": "",
        "ENABLE_BITCODE": "NO", "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "1",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "minimal",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO", "PRODUCT_NAME": "$(TARGET_NAME)",
        "GENERATE_INFOPLIST_FILE": "NO"})

    # ---- group tree -> resolved paths
    main_group = get(project.get("mainGroup"), "PBXGroup", "mainGroup")
    resolved = {}       # file ref id -> path relative to project root (or None for SDKROOT/BUILT_PRODUCTS_DIR)
    visited_groups = set()

    def walk(gid, base):
        if gid in visited_groups:
            fail("group %s is reachable twice / cycle" % gid)
            return
        visited_groups.add(gid)
        g = get(gid, None, "group child")
        if g is None:
            return
        for cid in g.get("children", []):
            c = get(cid, None, "children of %s" % g.get("path", g.get("name", gid)))
            if c is None:
                continue
            isa = c.get("isa")
            if isa == "PBXGroup":
                sub = base
                if "path" in c:
                    sub = (base + "/" if base else "") + c["path"]
                walk(cid, sub)
            elif isa == "PBXFileReference":
                st = c.get("sourceTree")
                if st == "<group>":
                    resolved[cid] = (base + "/" if base else "") + c.get("path", "")
                else:
                    resolved[cid] = None
            else:
                fail("group child %s has unexpected isa %s" % (cid, isa))

    if main_group is not None:
        walk(project["mainGroup"], "")

    for fid, path in resolved.items():
        if path is None:
            continue
        if not os.path.exists(os.path.join(ROOT, path.replace("/", os.sep))):
            fail("file reference %s points to a missing path: %s" % (fid, path))
    for fid in by_isa.get("PBXFileReference", []):
        if fid not in resolved:
            fail("PBXFileReference %s is not part of the group tree" % fid)

    # ---- build phases
    phases = {}
    for pid in target.get("buildPhases", []):
        ph = get(pid, None, "target.buildPhases")
        if ph is not None:
            phases[ph.get("isa")] = ph
    for want in ("PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"):
        if want not in phases:
            fail("target is missing %s" % want)

    def phase_paths(isa):
        res = []
        ph = phases.get(isa)
        if ph is None:
            return res
        for bid in ph.get("files", []):
            bf = get(bid, "PBXBuildFile", isa)
            if bf is None:
                continue
            fr = bf.get("fileRef")
            if fr not in resolved:
                fail("build file %s references %s which is not in the group tree" % (bid, fr))
                continue
            res.append(resolved[fr] if resolved[fr] is not None else "sdk:" + str(objs[fr].get("name")))
        return res

    src_paths = phase_paths("PBXSourcesBuildPhase")
    res_paths = phase_paths("PBXResourcesBuildPhase")
    fw_paths = phase_paths("PBXFrameworksBuildPhase")

    disk_swift = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, "Supercars")):
        rel_dir = os.path.relpath(dirpath, ROOT).replace(os.sep, "/")
        if rel_dir == "Supercars/Resources" or rel_dir.startswith("Supercars/Resources/"):
            dirnames[:] = []
            continue
        for fn in filenames:
            if fn.endswith(".swift"):
                disk_swift.append(rel_dir + "/" + fn)
    for path in disk_swift:
        n = src_paths.count(path)
        if n != 1:
            fail("%s appears %d times in the Sources phase (expected 1)" % (path, n))
    for path in src_paths:
        if path not in disk_swift:
            fail("Sources phase contains a non-existent / non-swift file: %s" % path)
    if len(set(src_paths)) != len(src_paths):
        fail("duplicate entries in the Sources phase")

    expect_res = ["Supercars/Resources/Assets.xcassets"] + ["Supercars/Resources/" + n for n in ("Models", "Textures", "Data", "Audio")]
    for path in expect_res:
        if res_paths.count(path) != 1:
            fail("%s appears %d times in the Resources phase (expected 1)" % (path, res_paths.count(path)))
    for path in res_paths:
        if path not in expect_res:
            fail("unexpected file in the Resources phase: %s" % path)
    if "Supercars/Resources/Info.plist" in res_paths + src_paths:
        fail("Info.plist must not be in a build phase")
    for fid, path in resolved.items():
        if path == "Supercars/Resources/Info.plist" and objs[fid].get("lastKnownFileType") != "text.plist.xml":
            fail("Info.plist file type should be text.plist.xml")
        if path == "Supercars/Resources/Assets.xcassets" and objs[fid].get("lastKnownFileType") != "folder.assetcatalog":
            fail("Assets.xcassets file type should be folder.assetcatalog")
        if path in expect_res[1:] and objs[fid].get("lastKnownFileType") != "folder":
            fail("%s must be a folder reference (lastKnownFileType = folder)" % path)

    want_fw = ["SceneKit", "SwiftUI", "AVFoundation", "CoreMotion", "GameController", "CoreHaptics", "Combine", "ModelIO", "Metal", "QuartzCore"]
    have_fw = sorted(p.replace("sdk:", "").replace(".framework", "") for p in fw_paths)
    if have_fw != sorted(want_fw):
        fail("frameworks mismatch: have %s want %s" % (have_fw, sorted(want_fw)))

    # every build file is used exactly once
    used = []
    for isa in phases:
        used.extend(phases[isa].get("files", []))
    for bid in by_isa.get("PBXBuildFile", []):
        if used.count(bid) != 1:
            fail("PBXBuildFile %s is used %d times" % (bid, used.count(bid)))

    # ---- disk-side checks
    plist_path = os.path.join(ROOT, "Supercars", "Resources", "Info.plist")
    try:
        with open(plist_path, "rb") as f:
            info = plistlib.load(f)
        if info.get("UIRequiresFullScreen") is not True:
            fail("Info.plist: UIRequiresFullScreen missing")
        if "UIApplicationSceneManifest" in info:
            fail("Info.plist: must not contain a scene manifest")
        orient = info.get("UISupportedInterfaceOrientations", [])
        if sorted(orient) != ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]:
            fail("Info.plist: orientations are not landscape only")
        for k in ("NSMotionUsageDescription", "CFBundleDisplayName", "UILaunchScreen", "UIRequiredDeviceCapabilities"):
            if k not in info:
                fail("Info.plist: missing %s" % k)
    except Exception as e:  # noqa
        fail("Info.plist does not parse: %s" % e)

    xc = os.path.join(ROOT, "Supercars", "Resources", "Assets.xcassets")
    for dirpath, dirnames, filenames in os.walk(xc):
        for fn in filenames:
            if fn == "Contents.json":
                try:
                    with open(os.path.join(dirpath, fn), "r", encoding="utf-8") as f:
                        json.load(f)
                except Exception as e:  # noqa
                    fail("%s: invalid JSON (%s)" % (os.path.join(dirpath, fn), e))
    icon_dir = os.path.join(xc, "AppIcon.appiconset")
    try:
        with open(os.path.join(icon_dir, "Contents.json"), "r", encoding="utf-8") as f:
            cj = json.load(f)
        imgs = cj.get("images", [])
        if len(imgs) != 1 or imgs[0].get("size") != "1024x1024" or imgs[0].get("platform") != "ios" or imgs[0].get("idiom") != "universal":
            fail("AppIcon Contents.json is not the single-size universal ios 1024x1024 format")
        else:
            png = os.path.join(icon_dir, imgs[0].get("filename", "missing.png"))
            with open(png, "rb") as f:
                head = f.read(33)
            if head[:8] != b"\x89PNG\r\n\x1a\n":
                fail("AppIcon file is not a PNG")
            else:
                w, h, depth, ctype = struct.unpack(">IIBB", head[16:26])
                if (w, h) != (1024, 1024):
                    fail("AppIcon is %dx%d, expected 1024x1024" % (w, h))
                if ctype not in (2, 3, 0):    # 2 = RGB, 3 = palette, 0 = grey; 6/4 would carry alpha
                    fail("AppIcon has an alpha channel (PNG colour type %d)" % ctype)
    except Exception as e:  # noqa
        fail("AppIcon check failed: %s" % e)
    if not os.path.exists(os.path.join(xc, "AccentColor.colorset", "Contents.json")):
        fail("AccentColor.colorset missing")

    # ---- workspace + scheme
    ws = os.path.join(PROJ, "project.xcworkspace", "contents.xcworkspacedata")
    if not os.path.exists(ws):
        fail("missing project.xcworkspace/contents.xcworkspacedata")
    else:
        try:
            ET.parse(ws)
        except ET.ParseError as e:
            fail("workspace file is not valid XML: %s" % e)
    scheme_path = os.path.join(PROJ, "xcshareddata", "xcschemes", "Supercars.xcscheme")
    try:
        tree = ET.parse(scheme_path)
        refs = list(tree.getroot().iter("BuildableReference"))
        if not refs:
            fail("scheme has no BuildableReference")
        for r in refs:
            if r.get("BlueprintIdentifier") != targets[0]:
                fail("scheme BlueprintIdentifier %s != target id %s" % (r.get("BlueprintIdentifier"), targets[0]))
            if r.get("BlueprintName") != "Supercars" or r.get("BuildableName") != "Supercars.app":
                fail("scheme BuildableName/BlueprintName mismatch")
            if r.get("ReferencedContainer") != "container:Supercars.xcodeproj":
                fail("scheme ReferencedContainer is wrong")
        arch = tree.getroot().find("ArchiveAction")
        if arch is None or arch.get("buildConfiguration") != "Release":
            fail("scheme ArchiveAction must use Release")
        entry = tree.getroot().find("BuildAction/BuildActionEntries/BuildActionEntry")
        if entry is None or entry.get("buildForArchiving") != "YES":
            fail("scheme build entry must build for archiving")
    except Exception as e:  # noqa
        fail("scheme check failed: %s" % e)

    # ---- project.yml agreement (optional)
    try:
        import yaml
        with open(os.path.join(ROOT, "project.yml"), "r", encoding="utf-8") as f:
            y = yaml.safe_load(f)
        t = y["targets"]["Supercars"]
        yfw = sorted(d["sdk"].replace(".framework", "") for d in t["dependencies"])
        if yfw != sorted(want_fw):
            fail("project.yml frameworks differ from the pbxproj: %s" % yfw)
        if t["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"] != "com.c0derz.supercars":
            fail("project.yml bundle id differs")
        folders = sorted(os.path.basename(s["path"]) for s in t["sources"] if isinstance(s, dict) and s.get("type") == "folder")
        if folders != sorted(["Models", "Textures", "Data", "Audio"]):
            fail("project.yml folder references differ: %s" % folders)
    except ImportError:
        warnings.append("PyYAML not installed: project.yml not cross-checked")
    except Exception as e:  # noqa
        fail("project.yml check failed: %s" % e)

    print("objects: %d   swift files in Sources: %d   resources: %d   frameworks: %d" % (len(objs), len(src_paths), len(res_paths), len(fw_paths)))
    return finish()


def finish():
    for w in warnings:
        print("warning:", w)
    if problems:
        print("\n%d PROBLEM(S):" % len(problems))
        for p in problems:
            print("  -", p)
        return 1
    print("check_xcodeproj: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
