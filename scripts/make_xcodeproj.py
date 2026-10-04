"""
Writes ios/Parley.xcodeproj (project.pbxproj + shared scheme).

The project uses Xcode 16+ "folder-synchronized" groups: every file under ios/Parley, ios/ParleyWidgets
and ios/Shared is part of its target(s) automatically, so adding a Swift file needs no project edit.
Run this again only to change targets or build settings:

    python scripts/make_xcodeproj.py
"""
import os

IOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ios")
PROJ = os.path.join(IOS, "Parley.xcodeproj")

ID = {name: "A1B2C3D4E5F6%012X" % i for i, name in enumerate([
    "project", "main_group", "products_group", "config_group",
    "sync_parley", "sync_shared", "sync_widgets",
    "app_product", "widget_product",
    "f_xcconfig", "f_app_info", "f_widget_info", "f_entitlements", "f_storekit",
    "app_target", "widget_target",
    "app_sources", "app_frameworks", "app_resources", "app_embed",
    "widget_sources", "widget_frameworks", "widget_resources",
    "bf_appex", "proxy", "dependency",
    "proj_configs", "proj_debug", "proj_release",
    "app_configs", "app_debug", "app_release",
    "widget_configs", "widget_debug", "widget_release",
], start=1)}

COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
    "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++20"',
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_COMMA": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
    "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
    "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
    "CLANG_WARN_STRICT_PROTOTYPES": "YES",
    "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}
PROJ_DEBUG = {**COMMON,
              "DEBUG_INFORMATION_FORMAT": "dwarf",
              "ENABLE_TESTABILITY": "YES",
              "GCC_DYNAMIC_NO_PIC": "NO",
              "GCC_OPTIMIZATION_LEVEL": "0",
              "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
              "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
              "ONLY_ACTIVE_ARCH": "YES",
              "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
              "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"'}
PROJ_RELEASE = {**COMMON,
                "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
                "ENABLE_NS_ASSERTIONS": "NO",
                "MTL_ENABLE_DEBUG_INFO": "NO",
                "SWIFT_COMPILATION_MODE": "wholemodule",
                "VALIDATE_PRODUCT": "YES"}
APP = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_ENTITLEMENTS": "Config/Parley.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": '"Config/Parley-Info.plist"',
    "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
    "PRODUCT_BUNDLE_IDENTIFIER": '"$(PARLEY_BUNDLE_ID)"',
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "TARGETED_DEVICE_FAMILY": "1",
}
WIDGET = {
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": '"Config/ParleyWidgets-Info.plist"',
    "LD_RUNPATH_SEARCH_PATHS": ('(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",'
                                '\n\t\t\t\t\t"@executable_path/../../Frameworks",\n\t\t\t\t)'),
    "PRODUCT_BUNDLE_IDENTIFIER": '"$(PARLEY_BUNDLE_ID).widgets"',
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
    "SUPPORTS_MACCATALYST": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "TARGETED_DEVICE_FAMILY": "1",
}


def settings(d):
    return "".join("\t\t\t\t%s = %s;\n" % (k, v) for k, v in sorted(d.items()))


def config(key, name, values, base=None):
    b = "\t\t\tbaseConfigurationReference = %s /* Parley.xcconfig */;\n" % ID["f_xcconfig"] if base else ""
    return ("\t\t%s /* %s */ = {\n\t\t\tisa = XCBuildConfiguration;\n%s\t\t\tbuildSettings = {\n%s\t\t\t};\n"
            "\t\t\tname = %s;\n\t\t};\n") % (ID[key], name, b, settings(values), name)


def pbxproj():
    I = ID
    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
		{I['bf_appex']} /* ParleyWidgets.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {I['widget_product']} /* ParleyWidgets.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		{I['proxy']} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {I['project']} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {I['widget_target']};
			remoteInfo = ParleyWidgets;
		}};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
		{I['app_embed']} /* Embed Foundation Extensions */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				{I['bf_appex']} /* ParleyWidgets.appex in Embed Foundation Extensions */,
			);
			name = "Embed Foundation Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
		{I['app_product']} /* Parley.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Parley.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['widget_product']} /* ParleyWidgets.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = ParleyWidgets.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['f_xcconfig']} /* Parley.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Parley.xcconfig; sourceTree = "<group>"; }};
		{I['f_app_info']} /* Parley-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Parley-Info.plist"; sourceTree = "<group>"; }};
		{I['f_widget_info']} /* ParleyWidgets-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "ParleyWidgets-Info.plist"; sourceTree = "<group>"; }};
		{I['f_entitlements']} /* Parley.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Parley.entitlements; sourceTree = "<group>"; }};
		{I['f_storekit']} /* Products.storekit */ = {{isa = PBXFileReference; lastKnownFileType = text; path = Products.storekit; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{I['sync_parley']} /* Parley */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = Parley;
			sourceTree = "<group>";
		}};
		{I['sync_shared']} /* Shared */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = Shared;
			sourceTree = "<group>";
		}};
		{I['sync_widgets']} /* ParleyWidgets */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = ParleyWidgets;
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{I['app_frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['widget_frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{I['main_group']} = {{
			isa = PBXGroup;
			children = (
				{I['sync_parley']} /* Parley */,
				{I['sync_widgets']} /* ParleyWidgets */,
				{I['sync_shared']} /* Shared */,
				{I['config_group']} /* Config */,
				{I['products_group']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{I['config_group']} /* Config */ = {{
			isa = PBXGroup;
			children = (
				{I['f_xcconfig']} /* Parley.xcconfig */,
				{I['f_app_info']} /* Parley-Info.plist */,
				{I['f_widget_info']} /* ParleyWidgets-Info.plist */,
				{I['f_entitlements']} /* Parley.entitlements */,
				{I['f_storekit']} /* Products.storekit */,
			);
			path = Config;
			sourceTree = "<group>";
		}};
		{I['products_group']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{I['app_product']} /* Parley.app */,
				{I['widget_product']} /* ParleyWidgets.appex */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{I['app_target']} /* Parley */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['app_configs']} /* Build configuration list for PBXNativeTarget "Parley" */;
			buildPhases = (
				{I['app_sources']} /* Sources */,
				{I['app_frameworks']} /* Frameworks */,
				{I['app_resources']} /* Resources */,
				{I['app_embed']} /* Embed Foundation Extensions */,
			);
			buildRules = (
			);
			dependencies = (
				{I['dependency']} /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				{I['sync_parley']} /* Parley */,
				{I['sync_shared']} /* Shared */,
			);
			name = Parley;
			packageProductDependencies = (
			);
			productName = Parley;
			productReference = {I['app_product']} /* Parley.app */;
			productType = "com.apple.product-type.application";
		}};
		{I['widget_target']} /* ParleyWidgets */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['widget_configs']} /* Build configuration list for PBXNativeTarget "ParleyWidgets" */;
			buildPhases = (
				{I['widget_sources']} /* Sources */,
				{I['widget_frameworks']} /* Frameworks */,
				{I['widget_resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{I['sync_widgets']} /* ParleyWidgets */,
				{I['sync_shared']} /* Shared */,
			);
			name = ParleyWidgets;
			packageProductDependencies = (
			);
			productName = ParleyWidgets;
			productReference = {I['widget_product']} /* ParleyWidgets.appex */;
			productType = "com.apple.product-type.app-extension";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{I['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
				TargetAttributes = {{
					{I['app_target']} = {{
						CreatedOnToolsVersion = 26.0;
					}};
					{I['widget_target']} = {{
						CreatedOnToolsVersion = 26.0;
					}};
				}};
			}};
			buildConfigurationList = {I['proj_configs']} /* Build configuration list for PBXProject "Parley" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
				fr,
			);
			mainGroup = {I['main_group']};
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = {I['products_group']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{I['app_target']} /* Parley */,
				{I['widget_target']} /* ParleyWidgets */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{I['app_resources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['widget_resources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{I['app_sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['widget_sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		{I['dependency']} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {I['widget_target']} /* ParleyWidgets */;
			targetProxy = {I['proxy']} /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
{config('proj_debug', 'Debug', PROJ_DEBUG, base=True)}{config('proj_release', 'Release', PROJ_RELEASE, base=True)}{config('app_debug', 'Debug', APP)}{config('app_release', 'Release', APP)}{config('widget_debug', 'Debug', WIDGET)}{config('widget_release', 'Release', WIDGET)}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{I['proj_configs']} /* Build configuration list for PBXProject "Parley" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['proj_debug']} /* Debug */,
				{I['proj_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{I['app_configs']} /* Build configuration list for PBXNativeTarget "Parley" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['app_debug']} /* Debug */,
				{I['app_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{I['widget_configs']} /* Build configuration list for PBXNativeTarget "ParleyWidgets" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['widget_debug']} /* Debug */,
				{I['widget_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {I['project']} /* Project object */;
}}
"""


def scheme():
    ref = """<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "%s"
               BuildableName = "Parley.app"
               BlueprintName = "Parley"
               ReferencedContainer = "container:Parley.xcodeproj">
            </BuildableReference>""" % ID["app_target"]
    return """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
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
            %(ref)s
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
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
         %(ref)s
      </BuildableProductRunnable>
      <StoreKitConfigurationFileReference
         identifier = "../Config/Products.storekit">
      </StoreKitConfigurationFileReference>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         %(ref)s
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""" % {"ref": ref}


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
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("wrote", os.path.relpath(path, os.path.join(IOS, "..")))


if __name__ == "__main__":
    write(os.path.join(PROJ, "project.pbxproj"), pbxproj())
    write(os.path.join(PROJ, "project.xcworkspace", "contents.xcworkspacedata"), WORKSPACE)
    write(os.path.join(PROJ, "xcshareddata", "xcschemes", "Parley.xcscheme"), scheme())
