#import "DebPathRedirect.h"
#include "../litehook/src/litehook.h"
#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// Redirect table: each entry maps an absolute path prefix a deb-imported tweak's
// compiled-in strings might reference (e.g. "/Library/Application Support/Foo.bundle"
// or "/var/jb/Library/Frameworks/Foo.framework") to where DebImporter.swift actually
// put that resource inside the LiveContainer tweak folder.
typedef struct {
    char *from;
    size_t fromLen;
    char *to;
} LCDebRedirect;

static LCDebRedirect *sRedirects = NULL;
static NSUInteger sRedirectCount = 0;

static void loadRedirectsFromPlist(NSString *plistPath, NSMutableDictionary<NSString *, NSString *> *merged) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![dict isKindOfClass:NSDictionary.class]) return;
    for (NSString *from in dict) {
        id to = dict[from];
        if ([from isKindOfClass:NSString.class] && [to isKindOfClass:NSString.class]) {
            merged[from] = to;
        }
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

static int (*orig_open)(const char *, int, ...) = open;
static int lc_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
        return orig_open(rewritePath(path), oflag, mode);
    }
    return orig_open(rewritePath(path), oflag);
}

static int (*orig_stat)(const char *, struct stat *) = stat;
static int lc_stat(const char *path, struct stat *buf) {
    return orig_stat(rewritePath(path), buf);
}

static int (*orig_lstat)(const char *, struct stat *) = lstat;
static int lc_lstat(const char *path, struct stat *buf) {
    return orig_lstat(rewritePath(path), buf);
}

static int (*orig_access)(const char *, int) = access;
static int lc_access(const char *path, int mode) {
    return orig_access(rewritePath(path), mode);
}

static char *(*orig_realpath)(const char *, char *) = realpath;
static char *lc_realpath(const char *path, char *resolved) {
    return orig_realpath(rewritePath(path), resolved);
}

static FILE *(*orig_fopen)(const char *, const char *) = fopen;
static FILE *lc_fopen(const char *path, const char *mode) {
    return orig_fopen(rewritePath(path), mode);
}

static DIR *(*orig_opendir)(const char *) = opendir;
static DIR *lc_opendir(const char *path) {
    return orig_opendir(rewritePath(path));
}

void DebPathRedirectInit(NSString *globalTweakFolder, NSString *selectedTweakFolderPath) {
    NSMutableDictionary<NSString *, NSString *> *merged = [NSMutableDictionary new];
    if (globalTweakFolder) {
        loadRedirectsFromPlist([globalTweakFolder stringByAppendingPathComponent:@".lc_deb_redirects.plist"], merged);
    }
    if (selectedTweakFolderPath) {
        loadRedirectsFromPlist([selectedTweakFolderPath stringByAppendingPathComponent:@".lc_deb_redirects.plist"], merged);
    }
    if (merged.count == 0) return;

    sRedirectCount = merged.count;
    sRedirects = calloc(sRedirectCount, sizeof(LCDebRedirect));
    NSUInteger i = 0;
    for (NSString *from in merged) {
        sRedirects[i].from = strdup(from.fileSystemRepresentation);
        sRedirects[i].fromLen = strlen(sRedirects[i].from);
        sRedirects[i].to = strdup(merged[from].fileSystemRepresentation);
        i++;
    }
    // longest (most specific) prefix first, so a nested path never matches a shorter parent by accident
    qsort_b(sRedirects, sRedirectCount, sizeof(LCDebRedirect), ^int(const void *a, const void *b) {
        return (int)(((const LCDebRedirect *)b)->fromLen - ((const LCDebRedirect *)a)->fromLen);
    });

    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, open, lc_open, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, stat, lc_stat, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, lstat, lc_lstat, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, access, lc_access, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, realpath, lc_realpath, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, fopen, lc_fopen, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, opendir, lc_opendir, nil);
}
