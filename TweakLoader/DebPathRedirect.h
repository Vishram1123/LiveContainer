#import <Foundation/Foundation.h>

// Rewrites hardcoded absolute paths that deb-imported tweaks use to find their own
// resource bundles/frameworks (e.g. /Library/Application Support/Foo.bundle,
// /var/jb/Library/Frameworks/Foo.framework) to wherever DebImporter actually placed
// them on disk, so NSBundle/CFBundle/open() lookups made by the tweak's own code
// still resolve inside LiveContainer's sandbox.
void DebPathRedirectInit(NSString *globalTweakFolder, NSString *selectedTweakFolderPath);
