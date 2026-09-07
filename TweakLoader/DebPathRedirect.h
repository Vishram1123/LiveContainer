#import <Foundation/Foundation.h>

// Rewrites hardcoded absolute paths that deb-imported tweaks use to find their own
// resource bundles/frameworks (e.g. /Library/Application Support/Foo.bundle,
// /var/jb/Library/Frameworks/Foo.framework) to wherever DebImporter actually placed
// them on disk, so NSBundle/CFBundle/open() lookups made by the tweak's own code
// still resolve inside LiveContainer's sandbox.
// isGroupTweakFolder tells us which of the two physical tweak-folder roots
// globalTweakFolder actually is this launch (LCPath.tweakPath vs
// LCPath.lcGroupTweakPath) -- redirect data is stored in NSUserDefaults keyed
// separately per root, since the same launch's globalTweakFolder never points at
// both at once, but a device can have deb-imported tweaks recorded under either.
void DebPathRedirectInit(NSString *globalTweakFolder, NSString *selectedTweakFolderPath, BOOL isGroupTweakFolder);
