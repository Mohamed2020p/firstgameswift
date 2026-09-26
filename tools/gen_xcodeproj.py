# -*- coding: utf-8 -*-
"""
Writes a complete, valid classic-format Xcode project for SUPERCARS without XcodeGen or Xcode:

    Supercars.xcodeproj/project.pbxproj
    Supercars.xcodeproj/project.xcworkspace/contents.xcworkspacedata
    Supercars.xcodeproj/xcshareddata/xcschemes/Supercars.xcscheme

Every .swift file under Supercars/ (except Supercars/Resources) is walked at generation time, so simply re-run
    python tools/gen_xcodeproj.py
after adding files.  Object ids are deterministic (md5 of a namespaced path).
This is the committed FALLBACK; Bitrise first tries `xcodegen generate --spec project.yml` (keep both in sync).
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

TARGET_NAME = "Supercars"
PROJECT_NAME = "Supercars"
SRC_DIR = "Supercars"
BUNDLE_ID = "com.c0derz.supercars"
INFO_PLIST = "Supercars/Resources/Info.plist"
ASSET_CATALOG = "Assets.xcassets"
FOLDER_REFS = ["Models", "Textures", "Data", "Audio"]
FRAMEWORKS = ["SceneKit", "SwiftUI", "AVFoundation", "CoreMotion", "GameController", "CoreHaptics", "Combine",
              "ModelIO", "Metal", "QuartzCore"]
DEPLOYMENT_TARGET = "16.0"

_used_ids = {}


def oid(namespace, path):
    """deterministic 24 hex digit object id"""
    key = namespace + ":" + path
    h = hashlib.md5(key.encode("utf-8")).hexdigest().upper()[:24]
    if h in _used_ids and _used_ids[h] != key:
        raise RuntimeError("object id collision: %s vs %s" % (key, _used_ids[h]))
    _used_ids[h] = key
    return h


# ----------------------------------------------------------------------------- OpenStep plist writer
def _needs_quotes(s):
    if s == "":
        return True
    for ch in s:
        if not (ch.isalnum() and ord(ch) < 128) and ch not in "_$/.":
            return True
    return False


def q(s):
    if not _needs_quotes(s):
        return s
    esc = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return '"' + esc + '"'


class Raw(str):
    """a value emitted verbatim (ids / already formatted)"""


def emit(value, indent=0):
    tab = "\t"
    pad = tab * indent
    if isinstance(value, Raw):
        return str(value)
    if isinstance(value, str):
        return q(value)
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, dict):
        if not value:
            return "{\n" + pad + "}"
        lines = ["{"]
        for k, v in value.items():
            lines.append("%s%s%s = %s;" % (pad, tab, q(k), emit(v, indent + 1)))
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(value, (list, tuple)):
        if not value:
            return "(\n" + pad + ")"
        lines = ["("]
        for v in value:
            lines.append("%s%s%s," % (pad, tab, emit(v, indent + 1)))
        lines.append(pad + ")")
        return "\n".join(lines)
    raise TypeError("cannot emit %r" % (value,))


def emit_object_line(obj):
    """single-line form used by Xcode for PBXBuildFile / PBXFileReference"""
    parts = []
    for k, v in obj.items():
        if isinstance(v, (list, tuple, dict)):
            raise TypeError("single-line objects only take scalars")
        parts.append("%s = %s;" % (q(k), emit(v)))
    return "{" + " ".join(parts) + " }"


# ----------------------------------------------------------------------------- file system walk
def ensure_placeholders():
    res = os.path.join(ROOT, SRC_DIR, "Resources")
    for name in FOLDER_REFS:
        d = os.path.join(res, name)
        os.makedirs(d, exist_ok=True)
        if not os.listdir(d):
            open(os.path.join(d, ".gitkeep"), "w").close()
    os.makedirs(os.path.join(res, ASSET_CATALOG), exist_ok=True)


def walk_swift_tree():
    """returns nested dict {'dirs': {name: node}, 'files': [names]} of swift files under Supercars/ (excluding Resources)"""
    def build(abs_dir, rel_dir):
        node = {"dirs": {}, "files": []}
        for name in sorted(os.listdir(abs_dir)):
            full = os.path.join(abs_dir, name)
            rel = rel_dir + "/" + name
            if os.path.isdir(full):
                if rel == SRC_DIR + "/Resources":
                    continue
                if name.startswith("."):
                    continue
                child = build(full, rel)
                if child["dirs"] or child["files"]:
                    node["dirs"][name] = child
            elif name.endswith(".swift"):
                node["files"].append(name)
        return node
    return build(os.path.join(ROOT, SRC_DIR), SRC_DIR)


# ----------------------------------------------------------------------------- build settings
def project_settings(config):
    s = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
    }
    if config == "Debug":
        s.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        })
    else:
        s.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "GCC_OPTIMIZATION_LEVEL": "s",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "VALIDATE_PRODUCT": "YES",
        })
    return s


def target_settings(config):
    s = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_BITCODE": "NO",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": INFO_PLIST,
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }
    if config == "Debug":
        s["GCC_OPTIMIZATION_LEVEL"] = "0"
        s["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
    else:
        s["GCC_OPTIMIZATION_LEVEL"] = "s"
        s["SWIFT_OPTIMIZATION_LEVEL"] = "-O"
    return dict(sorted(s.items()))


# ----------------------------------------------------------------------------- pbxproj model
class Project:
    def __init__(self):
        self.build_files = []      # (id, dict)
        self.file_refs = []        # (id, dict)
        self.groups = []           # (id, dict)
        self.sources = []          # build file ids
        self.resources = []
        self.frameworks = []

    def add_file_ref(self, key, attrs):
        fid = oid("FR", key)
        self.file_refs.append((fid, attrs))
        return fid

    def add_build_file(self, key, file_id, comment_name):
        bid = oid("BF", key)
        self.build_files.append((bid, {"isa": "PBXBuildFile", "fileRef": Raw(file_id)}, comment_name))
        return bid


def build():
    ensure_placeholders()
    tree = walk_swift_tree()
    p = Project()
    comments = {}   # id -> comment text (for readability)

    # ---- swift groups / files
    def group_id_for(rel_path):
        return oid("GR", rel_path)

    groups = []   # list of (id, attrs)

    def build_group(node, rel_path, name):
        children = []
        for dname, dnode in node["dirs"].items():
            children.append(build_group(dnode, rel_path + "/" + dname, dname))
        for fname in node["files"]:
            key = rel_path + "/" + fname
            fid = p.add_file_ref(key, {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift", "path": fname, "sourceTree": "<group>"})
            comments[fid] = fname
            bid = p.add_build_file("src:" + key, fid, fname + " in Sources")
            p.sources.append(bid)
            children.append(fid)
        if rel_path == SRC_DIR:
            children.append(build_resources_group())
        gid = group_id_for(rel_path)
        attrs = {"isa": "PBXGroup", "children": [Raw(c) for c in children], "path": name, "sourceTree": "<group>"}
        groups.append((gid, attrs))
        comments[gid] = name
        return gid

    def build_resources_group():
        rel = SRC_DIR + "/Resources"
        children = []
        # Info.plist
        pid = p.add_file_ref(rel + "/Info.plist", {"isa": "PBXFileReference", "lastKnownFileType": "text.plist.xml", "path": "Info.plist", "sourceTree": "<group>"})
        comments[pid] = "Info.plist"
        children.append(pid)
        # asset catalog
        aid = p.add_file_ref(rel + "/" + ASSET_CATALOG, {"isa": "PBXFileReference", "lastKnownFileType": "folder.assetcatalog", "path": ASSET_CATALOG, "sourceTree": "<group>"})
        comments[aid] = ASSET_CATALOG
        children.append(aid)
        bid = p.add_build_file("res:" + rel + "/" + ASSET_CATALOG, aid, ASSET_CATALOG + " in Resources")
        p.resources.append(bid)
        # folder references
        for name in FOLDER_REFS:
            fid = p.add_file_ref(rel + "/" + name, {"isa": "PBXFileReference", "lastKnownFileType": "folder", "path": name, "sourceTree": "<group>"})
            comments[fid] = name
            children.append(fid)
            bid = p.add_build_file("res:" + rel + "/" + name, fid, name + " in Resources")
            p.resources.append(bid)
        gid = group_id_for(rel)
        groups.append((gid, {"isa": "PBXGroup", "children": [Raw(c) for c in children], "path": "Resources", "sourceTree": "<group>"}))
        comments[gid] = "Resources"
        return gid

    src_group_id = build_group(tree, SRC_DIR, SRC_DIR)

    # ---- frameworks
    fw_ref_ids = []
    for fw in FRAMEWORKS:
        fid = p.add_file_ref("fw:" + fw, {"isa": "PBXFileReference", "lastKnownFileType": "wrapper.framework",
                                           "name": fw + ".framework", "path": "System/Library/Frameworks/" + fw + ".framework",
                                           "sourceTree": "SDKROOT"})
        comments[fid] = fw + ".framework"
        fw_ref_ids.append(fid)
        bid = p.add_build_file("fw:" + fw, fid, fw + ".framework in Frameworks")
        p.frameworks.append(bid)

    fw_group_id = oid("GR", "Frameworks")
    groups.append((fw_group_id, {"isa": "PBXGroup", "children": [Raw(x) for x in fw_ref_ids], "name": "Frameworks", "sourceTree": "<group>"}))
    comments[fw_group_id] = "Frameworks"

    # ---- product
    product_id = oid("FR", "product:" + TARGET_NAME + ".app")
    product_attrs = {"isa": "PBXFileReference", "explicitFileType": "wrapper.application", "includeInIndex": 0,
                     "path": TARGET_NAME + ".app", "sourceTree": "BUILT_PRODUCTS_DIR"}
    comments[product_id] = TARGET_NAME + ".app"
    products_group_id = oid("GR", "Products")
    groups.append((products_group_id, {"isa": "PBXGroup", "children": [Raw(product_id)], "name": "Products", "sourceTree": "<group>"}))
    comments[products_group_id] = "Products"

    main_group_id = oid("GR", "mainGroup")
    groups.append((main_group_id, {"isa": "PBXGroup", "children": [Raw(src_group_id), Raw(fw_group_id), Raw(products_group_id)],
                                   "sourceTree": "<group>"}))

    # ---- phases / target / project
    sources_phase = oid("PH", "sources")
    frameworks_phase = oid("PH", "frameworks")
    resources_phase = oid("PH", "resources")
    target_id = oid("TG", TARGET_NAME)
    project_id = oid("PJ", PROJECT_NAME)
    target_cl = oid("CL", "target")
    project_cl = oid("CL", "project")
    cfg_ids = {
        ("project", "Debug"): oid("BC", "project:Debug"),
        ("project", "Release"): oid("BC", "project:Release"),
        ("target", "Debug"): oid("BC", "target:Debug"),
        ("target", "Release"): oid("BC", "target:Release"),
    }

    return {
        "p": p, "groups": groups, "comments": comments,
        "ids": {
            "sources_phase": sources_phase, "frameworks_phase": frameworks_phase, "resources_phase": resources_phase,
            "target": target_id, "project": project_id, "target_cl": target_cl, "project_cl": project_cl,
            "cfg": cfg_ids, "main_group": main_group_id, "products_group": products_group_id, "product": product_id,
        },
    }


def render_pbxproj(m):
    p = m["p"]
    ids = m["ids"]
    comments = m["comments"]

    def c(i):
        return " /* %s */" % comments[i] if i in comments else ""

    out = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")
    out.append("")

    # PBXBuildFile
    out.append("/* Begin PBXBuildFile section */")
    for (bid, attrs, cm) in sorted(p.build_files, key=lambda t: t[0]):
        fr = str(attrs["fileRef"])
        out.append("\t\t%s /* %s */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };" % (bid, cm, fr, comments.get(fr, "")))
    out.append("/* End PBXBuildFile section */")
    out.append("")

    # PBXFileReference
    out.append("/* Begin PBXFileReference section */")
    all_refs = list(p.file_refs) + [(ids["product"], {"isa": "PBXFileReference", "explicitFileType": "wrapper.application",
                                                       "includeInIndex": 0, "path": TARGET_NAME + ".app", "sourceTree": "BUILT_PRODUCTS_DIR"})]
    for (fid, attrs) in sorted(all_refs, key=lambda t: t[0]):
        out.append("\t\t%s /* %s */ = %s;" % (fid, comments.get(fid, ""), emit_object_line(attrs)))
    out.append("/* End PBXFileReference section */")
    out.append("")

    # PBXFrameworksBuildPhase
    out.append("/* Begin PBXFrameworksBuildPhase section */")
    body = {"isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647,
            "files": [Raw(b + " /* " + next(cm for (bid, a, cm) in p.build_files if bid == b) + " */") for b in p.frameworks],
            "runOnlyForDeploymentPostprocessing": 0}
    out.append("\t\t%s /* Frameworks */ = %s;" % (ids["frameworks_phase"], emit(body, 2)))
    out.append("/* End PBXFrameworksBuildPhase section */")
    out.append("")

    # PBXGroup
    out.append("/* Begin PBXGroup section */")
    for (gid, attrs) in sorted(m["groups"], key=lambda t: t[0]):
        attrs2 = dict(attrs)
        kids = []
        for k in attrs["children"]:
            kids.append(Raw(str(k) + " /* " + comments.get(str(k), "") + " */"))
        attrs2["children"] = kids
        label = comments.get(gid)
        head = "\t\t%s%s = %s;" % (gid, (" /* %s */" % label) if label else "", emit(attrs2, 2))
        out.append(head)
    out.append("/* End PBXGroup section */")
    out.append("")

    # PBXNativeTarget
    out.append("/* Begin PBXNativeTarget section */")
    target = {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": Raw(ids["target_cl"] + " /* Build configuration list for PBXNativeTarget \"%s\" */" % TARGET_NAME),
        "buildPhases": [Raw(ids["sources_phase"] + " /* Sources */"), Raw(ids["frameworks_phase"] + " /* Frameworks */"),
                        Raw(ids["resources_phase"] + " /* Resources */")],
        "buildRules": [],
        "dependencies": [],
        "name": TARGET_NAME,
        "productName": TARGET_NAME,
        "productReference": Raw(ids["product"] + " /* " + TARGET_NAME + ".app */"),
        "productType": "com.apple.product-type.application",
    }
    out.append("\t\t%s /* %s */ = %s;" % (ids["target"], TARGET_NAME, emit(target, 2)))
    out.append("/* End PBXNativeTarget section */")
    out.append("")

    # PBXProject
    out.append("/* Begin PBXProject section */")
    project = {
        "isa": "PBXProject",
        "attributes": {"BuildIndependentTargetsInParallel": 1, "LastSwiftUpdateCheck": 1500, "LastUpgradeCheck": 1500,
                       "TargetAttributes": {ids["target"]: {"CreatedOnToolsVersion": "15.0"}}},
        "buildConfigurationList": Raw(ids["project_cl"] + " /* Build configuration list for PBXProject \"%s\" */" % PROJECT_NAME),
        "compatibilityVersion": "Xcode 14.0",
        "developmentRegion": "en",
        "hasScannedForEncodings": 0,
        "knownRegions": ["en", "Base"],
        "mainGroup": Raw(ids["main_group"]),
        "productRefGroup": Raw(ids["products_group"] + " /* Products */"),
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [Raw(ids["target"] + " /* " + TARGET_NAME + " */")],
    }
    out.append("\t\t%s /* Project object */ = %s;" % (ids["project"], emit(project, 2)))
    out.append("/* End PBXProject section */")
    out.append("")

    # PBXResourcesBuildPhase
    out.append("/* Begin PBXResourcesBuildPhase section */")
    body = {"isa": "PBXResourcesBuildPhase", "buildActionMask": 2147483647,
            "files": [Raw(b + " /* " + next(cm for (bid, a, cm) in p.build_files if bid == b) + " */") for b in p.resources],
            "runOnlyForDeploymentPostprocessing": 0}
    out.append("\t\t%s /* Resources */ = %s;" % (ids["resources_phase"], emit(body, 2)))
    out.append("/* End PBXResourcesBuildPhase section */")
    out.append("")

    # PBXSourcesBuildPhase
    out.append("/* Begin PBXSourcesBuildPhase section */")
    body = {"isa": "PBXSourcesBuildPhase", "buildActionMask": 2147483647,
            "files": [Raw(b + " /* " + next(cm for (bid, a, cm) in p.build_files if bid == b) + " */") for b in p.sources],
            "runOnlyForDeploymentPostprocessing": 0}
    out.append("\t\t%s /* Sources */ = %s;" % (ids["sources_phase"], emit(body, 2)))
    out.append("/* End PBXSourcesBuildPhase section */")
    out.append("")

    # XCBuildConfiguration
    out.append("/* Begin XCBuildConfiguration section */")
    for scope in ("project", "target"):
        for cfg in ("Debug", "Release"):
            settings = project_settings(cfg) if scope == "project" else target_settings(cfg)
            body = {"isa": "XCBuildConfiguration", "buildSettings": dict(sorted(settings.items())), "name": cfg}
            out.append("\t\t%s /* %s */ = %s;" % (ids["cfg"][(scope, cfg)], cfg, emit(body, 2)))
    out.append("/* End XCBuildConfiguration section */")
    out.append("")

    # XCConfigurationList
    out.append("/* Begin XCConfigurationList section */")
    for (cl, scope, label) in ((ids["project_cl"], "project", 'PBXProject "%s"' % PROJECT_NAME),
                               (ids["target_cl"], "target", 'PBXNativeTarget "%s"' % TARGET_NAME)):
        body = {"isa": "XCConfigurationList",
                "buildConfigurations": [Raw(ids["cfg"][(scope, "Debug")] + " /* Debug */"), Raw(ids["cfg"][(scope, "Release")] + " /* Release */")],
                "defaultConfigurationIsVisible": 0,
                "defaultConfigurationName": "Release"}
        out.append("\t\t%s /* Build configuration list for %s */ = %s;" % (cl, label, emit(body, 2)))
    out.append("/* End XCConfigurationList section */")

    out.append("\t};")
    out.append("\trootObject = %s /* Project object */;" % ids["project"])
    out.append("}")
    out.append("")
    return "\n".join(out)


def render_scheme(target_id):
    return """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{tid}"
               BuildableName = "{name}.app"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{proj}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{tid}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{proj}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{tid}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{proj}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "NO">
   </ArchiveAction>
</Scheme>
""".format(tid=target_id, name=TARGET_NAME, proj=PROJECT_NAME)


WORKSPACE = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def main():
    m = build()
    proj_dir = os.path.join(ROOT, PROJECT_NAME + ".xcodeproj")
    write(os.path.join(proj_dir, "project.pbxproj"), render_pbxproj(m))
    write(os.path.join(proj_dir, "project.xcworkspace", "contents.xcworkspacedata"), WORKSPACE)
    write(os.path.join(proj_dir, "xcshareddata", "xcschemes", TARGET_NAME + ".xcscheme"), render_scheme(m["ids"]["target"]))
    print("wrote %s  (%d swift files, %d resources, %d frameworks)" % (proj_dir, len(m["p"].sources), len(m["p"].resources), len(m["p"].frameworks)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
