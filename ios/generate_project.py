#!/usr/bin/env python3
"""Generates DeckMobile.xcodeproj from the source tree.

Hand-maintaining a pbxproj means hand-maintaining 24-character object IDs, and a
single duplicated or dangling one produces an "unable to open project" with no
indication of which line is at fault. Generating it means adding a file is just
dropping it in the directory and re-running this.

IDs are derived from a hash of the object's role and path, so they are stable
across runs: regenerating does not produce a diff unless the file set changed.
"""

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)

APP = "DeckMobile"
BUNDLE_ID = "com.riddickburke.deckmobile"
TEAM_ID = "F4LTQQK7JP"
DEPLOYMENT_TARGET = "17.0"

# The portable half of DeckCore, compiled straight into the app target.
#
# The rest of DeckCore is macOS-only by nature: it shells out to ffmpeg/ffprobe,
# walks arbitrary filesystem paths, or drives a Rockbox device over USB. None of
# that exists on iOS, so rather than littering DeckCore with #if os(iOS) the
# iOS target simply compiles the files that are already portable.
SHARED_CORE = [
    "Sources/DeckCore/Models.swift",
    "Sources/DeckCore/Theme.swift",
    "Sources/DeckCore/Spectrum.swift",
    "Sources/DeckCore/SyntheticSpectrum.swift",
    "Sources/DeckCore/ServicePlaylist.swift",
]

FRAMEWORKS = ["MediaPlayer.framework", "AVFoundation.framework"]


def oid(role, path):
    """A stable 24-hex-character object ID."""
    return hashlib.sha1(f"{role}\x00{path}".encode()).hexdigest()[:24].upper()


def swift_sources():
    """App sources, sorted so the generated file is deterministic."""
    out = []
    base = os.path.join(ROOT, APP)
    for dirpath, _, filenames in os.walk(base):
        for name in sorted(filenames):
            if name.endswith(".swift"):
                full = os.path.join(dirpath, name)
                out.append(os.path.relpath(full, ROOT))
    return sorted(out)


def build_file_entries(paths):
    """(build-file id, file-ref id, path, name) for each source path."""
    return [(oid("buildfile", p), oid("fileref", p), p, os.path.basename(p)) for p in paths]


def main():
    app_sources = swift_sources()
    core_sources = [os.path.relpath(os.path.join(REPO, p), ROOT) for p in SHARED_CORE]

    app_files = build_file_entries(app_sources)
    core_files = build_file_entries(core_sources)
    all_files = app_files + core_files

    fw_files = [(oid("buildfile", f), oid("fileref", f), f, f) for f in FRAMEWORKS]

    assets_ref = oid("fileref", "Assets.xcassets")
    assets_build = oid("buildfile", "Assets.xcassets")

    # --- object ids -----------------------------------------------------
    project = oid("project", APP)
    target = oid("target", APP)
    product = oid("product", APP)
    main_group = oid("group", "main")
    app_group = oid("group", "app")
    views_group = oid("group", "views")
    core_group = oid("group", "core")
    fw_group = oid("group", "frameworks")
    products_group = oid("group", "products")
    sources_phase = oid("phase", "sources")
    frameworks_phase = oid("phase", "frameworks")
    resources_phase = oid("phase", "resources")
    project_config_list = oid("configlist", "project")
    target_config_list = oid("configlist", "target")
    proj_debug = oid("config", "project-debug")
    proj_release = oid("config", "project-release")
    tgt_debug = oid("config", "target-debug")
    tgt_release = oid("config", "target-release")

    L = []
    w = L.append

    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {\n\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")

    # --- PBXBuildFile ---------------------------------------------------
    w("\n/* Begin PBXBuildFile section */")
    for bid, fid, path, name in all_files:
        w(f"\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};")
    for bid, fid, path, name in fw_files:
        w(f"\t\t{bid} /* {name} in Frameworks */ = {{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};")
    w(f"\t\t{assets_build} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};")
    w("/* End PBXBuildFile section */")

    # --- PBXFileReference -----------------------------------------------
    w("\n/* Begin PBXFileReference section */")
    for bid, fid, path, name in all_files:
        w(f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = "{path}"; sourceTree = "<group>"; }};')
    for bid, fid, path, name in fw_files:
        w(f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {name}; path = System/Library/Frameworks/{name}; sourceTree = SDKROOT; }};')
    w(f'\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = "{APP}/Assets.xcassets"; sourceTree = "<group>"; }};')
    w(f'\t\t{product} /* {APP}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{APP}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
    w("/* End PBXFileReference section */")

    # --- PBXFrameworksBuildPhase ----------------------------------------
    w("\n/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for bid, fid, path, name in fw_files:
        w(f"\t\t\t\t{bid} /* {name} in Frameworks */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")

    # --- PBXGroup -------------------------------------------------------
    def group(gid, name, children, path=None):
        w(f"\t\t{gid} /* {name} */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for cid, cname in children:
            w(f"\t\t\t\t{cid} /* {cname} */,")
        w("\t\t\t);")
        w(f"\t\t\tname = {name};")
        if path:
            w(f"\t\t\tpath = {path};")
        w('\t\t\tsourceTree = "<group>";')
        w("\t\t};")

    top_level = [(b, n) for _, b, _, n in
                 [(x[0], x[1], x[2], x[3]) for x in app_files if "/Views/" not in x[2]]]
    view_level = [(x[1], x[3]) for x in app_files if "/Views/" in x[2]]

    w("\n/* Begin PBXGroup section */")
    group(main_group, "Deck", [
        (app_group, APP), (core_group, "DeckCore"),
        (assets_ref, "Assets.xcassets"),
        (fw_group, "Frameworks"), (products_group, "Products"),
    ])
    group(app_group, APP, top_level + [(views_group, "Views")])
    group(views_group, "Views", view_level)
    group(core_group, "DeckCore", [(x[1], x[3]) for x in core_files])
    group(fw_group, "Frameworks", [(x[1], x[3]) for x in fw_files])
    group(products_group, "Products", [(product, f"{APP}.app")])
    w("/* End PBXGroup section */")

    # --- PBXNativeTarget ------------------------------------------------
    w("\n/* Begin PBXNativeTarget section */")
    w(f"\t\t{target} /* {APP} */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {target_config_list};")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{sources_phase} /* Sources */,")
    w(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    w(f"\t\t\t\t{resources_phase} /* Resources */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (\n\t\t\t);")
    w("\t\t\tdependencies = (\n\t\t\t);")
    w(f"\t\t\tname = {APP};")
    w(f"\t\t\tproductName = {APP};")
    w(f"\t\t\tproductReference = {product} /* {APP}.app */;")
    w('\t\t\tproductType = "com.apple.product-type.application";')
    w("\t\t};")
    w("/* End PBXNativeTarget section */")

    # --- PBXProject -----------------------------------------------------
    w("\n/* Begin PBXProject section */")
    w(f"\t\t{project} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 2660;")
    w("\t\t\t\tLastUpgradeCheck = 2660;")
    w("\t\t\t\tTargetAttributes = {")
    w(f"\t\t\t\t\t{target} = {{ CreatedOnToolsVersion = 26.6; }};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {project_config_list};")
    w('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group};")
    w(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    w('\t\t\tprojectDirPath = "";')
    w('\t\t\tprojectRoot = "";')
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{target} /* {APP} */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")

    # --- PBXResourcesBuildPhase -----------------------------------------
    w("\n/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{resources_phase} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w(f"\t\t\t\t{assets_build} /* Assets.xcassets in Resources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")

    # --- PBXSourcesBuildPhase -------------------------------------------
    w("\n/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{sources_phase} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for bid, fid, path, name in all_files:
        w(f"\t\t\t\t{bid} /* {name} in Sources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")

    # --- XCBuildConfiguration -------------------------------------------
    common = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("COPY_PHASE_STRIP", "NO"),
        ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
        ("GCC_NO_COMMON_BLOCKS", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET),
        ("SDKROOT", "iphoneos"),
        ("SWIFT_VERSION", "5.0"),
        ("TARGETED_DEVICE_FAMILY", '"1,2"'),
    ]
    target_common = [
        ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("DEVELOPMENT_TEAM", TEAM_ID),
        ("ENABLE_PREVIEWS", "YES"),
        ("GENERATE_INFOPLIST_FILE", "NO"),
        ("INFOPLIST_FILE", f'"{APP}/Info.plist"'),
        ("LD_RUNPATH_SEARCH_PATHS", '"$(inherited) @executable_path/Frameworks"'),
        ("MARKETING_VERSION", "1.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID),
        ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
    ]

    def config(cid, name, settings):
        w(f"\t\t{cid} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        for k, v in settings:
            w(f"\t\t\t\t{k} = {v};")
        w("\t\t\t};")
        w(f"\t\t\tname = {name};")
        w("\t\t};")

    w("\n/* Begin XCBuildConfiguration section */")
    config(proj_debug, "Debug", common + [
        ("DEBUG_INFORMATION_FORMAT", "dwarf"),
        ("ENABLE_TESTABILITY", "YES"),
        ("GCC_OPTIMIZATION_LEVEL", "0"),
        ("ONLY_ACTIVE_ARCH", "YES"),
        ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
        ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"'),
    ])
    config(proj_release, "Release", common + [
        ("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'),
        ("ENABLE_NS_ASSERTIONS", "NO"),
        ("SWIFT_COMPILATION_MODE", "wholemodule"),
        ("VALIDATE_PRODUCT", "YES"),
    ])
    config(tgt_debug, "Debug", target_common)
    config(tgt_release, "Release", target_common)
    w("/* End XCBuildConfiguration section */")

    # --- XCConfigurationList --------------------------------------------
    def config_list(cid, name, debug, release):
        w(f"\t\t{cid} /* Build configuration list for {name} */ = {{")
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w(f"\t\t\t\t{debug} /* Debug */,")
        w(f"\t\t\t\t{release} /* Release */,")
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")

    w("\n/* Begin XCConfigurationList section */")
    config_list(project_config_list, "PBXProject", proj_debug, proj_release)
    config_list(target_config_list, "PBXNativeTarget", tgt_debug, tgt_release)
    w("/* End XCConfigurationList section */")

    w("\t};")
    w(f"\trootObject = {project} /* Project object */;")
    w("}")

    proj_dir = os.path.join(ROOT, f"{APP}.xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
        f.write("\n".join(L) + "\n")

    # A shared scheme, so `xcodebuild -scheme DeckMobile` works from a clean
    # checkout instead of only after Xcode has opened the project once.
    schemes = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(schemes, exist_ok=True)
    with open(os.path.join(schemes, f"{APP}.xcscheme"), "w") as f:
        f.write(SCHEME.format(app=APP, target=target, project=f"{APP}.xcodeproj"))

    print(f"wrote {proj_dir}")
    print(f"  {len(app_files)} app sources, {len(core_files)} shared core sources")


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2660" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "{app}.app"
               BlueprintName = "{app}"
               ReferencedContainer = "container:{project}">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{project}">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{project}">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""


if __name__ == "__main__":
    sys.exit(main())
