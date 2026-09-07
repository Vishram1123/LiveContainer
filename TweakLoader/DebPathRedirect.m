#import "DebPathRedirect.h"
#import "../LiveContainer/utils.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

// Redirect table: each entry maps an absolute path prefix a deb-imported tweak's
// compiled-in strings might reference (e.g. "/Library/Application Support/Foo.bundle"
// or "/var/jb/Library/Frameworks/Foo.framework") to where DebImporter.swift actually
// put that resource inside the LiveContainer tweak folder. Path keys start with "/";
// entries prefixed "id:" instead map a bundle's own CFBundleIdentifier to its path, for
// tweaks that look their bundle up by identifier rather than by path.
typedef struct {
    char *from;
    size_t fromLen;
    char *to;
} LCDebRedirect;

static LCDebRedirect *sRedirects = NULL;
static NSUInteger sRedirectCount = 0;
static LCDebRedirect *sIdentifierRedirects = NULL;
static NSUInteger sIdentifierRedirectCount = 0;

// Redirect data lives in NSUserDefaults (the App Group suite this codebase already uses
// for every other piece of persistent LiveContainer config) rather than a dotfile inside
// the user-browsable Tweaks folder. DebImporter.swift writes one top-level key per
// physical tweak-folder root (isGroupTweakFolder picks which), holding a dictionary of
// scopes -- "" for the root's own (global) entries, or a per-app-selected folder's name --
// each mapping a bare absolute path to a path *relative to that scope's own folder*. That
// relative storage (rather than an absolute path baked in at import time) is what lets the
// same entry keep resolving correctly however the container/root physically moves
// (LiveContainer reinstalled with a new sandbox UUID, or the tweak folder relocated by
// "convert to shared") -- reconstructing the absolute destination fresh, against whichever
// root/scope is actually current, is exactly what this does.
static void loadRedirectsFromDefaults(NSString *scopeFolder, NSString *scopeName, BOOL isGroupTweakFolder, NSMutableDictionary<NSString *, NSString *> *merged) {
    NSString *udKey = isGroupTweakFolder ? @"LCDebRedirectsGroup" : @"LCDebRedirectsPrivate";
    NSDictionary *allScopes = [NSUserDefaults.lcSharedDefaults dictionaryForKey:udKey];
    if (![allScopes isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dict = allScopes[scopeName];
    if (![dict isKindOfClass:NSDictionary.class]) return;
    for (NSString *from in dict) {
        id to = dict[from];
        if ([from isKindOfClass:NSString.class] && [to isKindOfClass:NSString.class]) {
            merged[from] = [scopeFolder stringByAppendingPathComponent:(NSString *)to];
        }
    }
}

// Tweaks/.lc_shared_jbroot is rebuilt from scratch on every launch (rather than persisted
// by DebImporter at import time) directly from `merged` -- which by this point already
// holds every currently-known redirect resolved to its real absolute path -- so it always
// reflects exactly what's importable right now, self-healing if a tweak was added, removed,
// or moved since the last launch, without DebImporter needing to maintain it as accumulated
// state. Every deb-imported tweak's own ".jbroot" symlink (see DebImporter.swift's
// createJbrootSymlink) and the extra rpath LCPatchAddRPath adds both point at this fixed
// location, so nothing needs to be re-patched when its contents change here.
static void rebuildSharedJbroot(NSString *globalTweakFolder, NSDictionary<NSString *, NSString *> *merged) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *sharedRoot = [globalTweakFolder stringByAppendingPathComponent:@".lc_shared_jbroot"];
    [fm removeItemAtPath:sharedRoot error:nil];
    [fm createDirectoryAtPath:sharedRoot withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *from in merged) {
        if (![from hasPrefix:@"/"] || [from hasPrefix:@"/var/jb/"]) continue;
        NSString *symlinkPath = [sharedRoot stringByAppendingPathComponent:from];
        NSString *symlinkDir = symlinkPath.stringByDeletingLastPathComponent;
        [fm createDirectoryAtPath:symlinkDir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createSymbolicLinkAtPath:symlinkPath withDestinationPath:merged[from] error:nil];
    }
}

static const char *rewritePath(const char *path) {
    if (!path || sRedirectCount == 0) return path;
    size_t pathLen = strlen(path);
    for (NSUInteger i = 0; i < sRedirectCount; i++) {
        LCDebRedirect *r = &sRedirects[i];
        if (pathLen >= r->fromLen && memcmp(path, r->from, r->fromLen) == 0 &&
            (path[r->fromLen] == '\0' || path[r->fromLen] == '/')) {
            static __thread char buffer[PATH_MAX];
            snprintf(buffer, sizeof(buffer), "%s%s", r->to, path + r->fromLen);
            return buffer;
        }
    }
    return path;
}

static const char *lookupIdentifierRedirect(const char *identifier) {
    if (!identifier) return NULL;
    for (NSUInteger i = 0; i < sIdentifierRedirectCount; i++) {
        if (strcmp(identifier, sIdentifierRedirects[i].from) == 0) {
            return sIdentifierRedirects[i].to;
        }
    }
    return NULL;
}

// NSBundle/CFBundle and NSFileManager do their actual filesystem work (stat/open) from
// inside CoreFoundation/Foundation, which live in the dyld shared cache -- calls a shared
// cache image makes to another shared cache image aren't interposable by rebinding a plain
// C symbol like open()/stat(), since the cache uses direct, pre-bound stubs for those
// intra-cache calls. Objective-C method dispatch isn't affected by that: it always goes
// through the class's method list, so swizzling the handful of NSBundle/NSFileManager
// entry points a tweak's own (non-cache) code calls into is what actually reaches these
// calls, the same way NSBundle+FixCydiaSubstrate.m and NSFileManager+GuestHooks.m already
// swizzle Foundation methods elsewhere in this codebase.
static NSString *lc_debRewritePath(NSString *path) {
    if (!path) return path;
    const char *original = path.fileSystemRepresentation;
    const char *rewritten = rewritePath(original);
    if (rewritten == original) return path;
    return [NSString stringWithUTF8String:rewritten];
}

static NSURL *lc_debRewriteFileURL(NSURL *url) {
    if (!url || !url.isFileURL) return url;
    NSString *rewritten = lc_debRewritePath(url.path);
    if ([rewritten isEqualToString:url.path]) return url;
    return [NSURL fileURLWithPath:rewritten];
}

@interface NSBundle (LCDebRedirect)
@end

@implementation NSBundle (LCDebRedirect)

+ (instancetype)lc_debRedirect_bundleWithPath:(NSString *)path {
    return [self lc_debRedirect_bundleWithPath:lc_debRewritePath(path)];
}

- (instancetype)lc_debRedirect_initWithPath:(NSString *)path {
    return [self lc_debRedirect_initWithPath:lc_debRewritePath(path)];
}

+ (instancetype)lc_debRedirect_bundleWithURL:(NSURL *)url {
    return [self lc_debRedirect_bundleWithURL:lc_debRewriteFileURL(url)];
}

- (instancetype)lc_debRedirect_initWithURL:(NSURL *)url {
    return [self lc_debRedirect_initWithURL:lc_debRewriteFileURL(url)];
}

+ (instancetype)lc_debRedirect_bundleWithIdentifier:(NSString *)identifier {
    NSBundle *result = [self lc_debRedirect_bundleWithIdentifier:identifier];
    if (result) return result;
    const char *path = lookupIdentifierRedirect(identifier.UTF8String);
    if (path) {
        return [NSBundle bundleWithPath:[NSString stringWithUTF8String:path]];
    }
    return result;
}

@end

@interface NSFileManager (LCDebRedirect)
@end

@implementation NSFileManager (LCDebRedirect)

- (BOOL)lc_debRedirect_fileExistsAtPath:(NSString *)path {
    return [self lc_debRedirect_fileExistsAtPath:lc_debRewritePath(path)];
}

- (BOOL)lc_debRedirect_fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    return [self lc_debRedirect_fileExistsAtPath:lc_debRewritePath(path) isDirectory:isDirectory];
}

- (NSArray<NSString *> *)lc_debRedirect_contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    return [self lc_debRedirect_contentsOfDirectoryAtPath:lc_debRewritePath(path) error:error];
}

@end

void DebPathRedirectInit(NSString *globalTweakFolder, NSString *selectedTweakFolderPath, BOOL isGroupTweakFolder) {
    NSMutableDictionary<NSString *, NSString *> *merged = [NSMutableDictionary new];
    if (globalTweakFolder) {
        loadRedirectsFromDefaults(globalTweakFolder, @"", isGroupTweakFolder, merged);
    }
    if (selectedTweakFolderPath) {
        loadRedirectsFromDefaults(selectedTweakFolderPath, selectedTweakFolderPath.lastPathComponent, isGroupTweakFolder, merged);
    }
    if (merged.count == 0) return;

    rebuildSharedJbroot(globalTweakFolder, merged);

    NSMutableArray<NSString *> *pathKeys = [NSMutableArray new];
    NSMutableArray<NSString *> *identifierKeys = [NSMutableArray new];
    for (NSString *key in merged) {
        if ([key hasPrefix:@"id:"]) {
            [identifierKeys addObject:key];
        } else {
            [pathKeys addObject:key];
        }
    }

    sRedirectCount = pathKeys.count;
    sRedirects = calloc(sRedirectCount, sizeof(LCDebRedirect));
    for (NSUInteger i = 0; i < pathKeys.count; i++) {
        NSString *from = pathKeys[i];
        sRedirects[i].from = strdup(from.fileSystemRepresentation);
        sRedirects[i].fromLen = strlen(sRedirects[i].from);
        sRedirects[i].to = strdup(merged[from].fileSystemRepresentation);
    }
    // longest (most specific) prefix first, so a nested path never matches a shorter parent by accident
    qsort_b(sRedirects, sRedirectCount, sizeof(LCDebRedirect), ^int(const void *a, const void *b) {
        return (int)(((const LCDebRedirect *)b)->fromLen - ((const LCDebRedirect *)a)->fromLen);
    });

    sIdentifierRedirectCount = identifierKeys.count;
    sIdentifierRedirects = calloc(sIdentifierRedirectCount, sizeof(LCDebRedirect));
    for (NSUInteger i = 0; i < identifierKeys.count; i++) {
        NSString *key = identifierKeys[i];
        NSString *identifier = [key substringFromIndex:3];
        sIdentifierRedirects[i].from = strdup(identifier.UTF8String);
        sIdentifierRedirects[i].to = strdup(merged[key].fileSystemRepresentation);
    }

    swizzleClassMethod(NSBundle.class, @selector(bundleWithPath:), @selector(lc_debRedirect_bundleWithPath:));
    swizzle(NSBundle.class, @selector(initWithPath:), @selector(lc_debRedirect_initWithPath:));
    swizzleClassMethod(NSBundle.class, @selector(bundleWithURL:), @selector(lc_debRedirect_bundleWithURL:));
    swizzle(NSBundle.class, @selector(initWithURL:), @selector(lc_debRedirect_initWithURL:));
    swizzleClassMethod(NSBundle.class, @selector(bundleWithIdentifier:), @selector(lc_debRedirect_bundleWithIdentifier:));

    swizzle(NSFileManager.class, @selector(fileExistsAtPath:), @selector(lc_debRedirect_fileExistsAtPath:));
    swizzle(NSFileManager.class, @selector(fileExistsAtPath:isDirectory:), @selector(lc_debRedirect_fileExistsAtPath:isDirectory:));
    swizzle(NSFileManager.class, @selector(contentsOfDirectoryAtPath:error:), @selector(lc_debRedirect_contentsOfDirectoryAtPath:error:));
}
