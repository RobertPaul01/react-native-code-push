#import "CodePush.h"
#include <CommonCrypto/CommonDigest.h>

@implementation CodePushUpdateUtils

NSString * const AssetsFolderName = @"assets";
NSString * const BinaryHashKey = @"CodePushBinaryHash";
NSString * const ManifestFolderPrefix = @"CodePush";

+ (void)addContentsOfFolderToManifest:(NSString *)folderPath
                           pathPrefix:(NSString *)pathPrefix
                             manifest:(NSMutableArray *)manifest
                                error:(NSError **)error
{
    NSArray* folderFiles = [[NSFileManager defaultManager]
                            contentsOfDirectoryAtPath:folderPath
                            error:error];
    if (*error) {
        return;
    }
    
    for (NSString *fileName in folderFiles) {
#if TARGET_IPHONE_SIMULATOR
        // If the user is running this in a simulator, there is a chance
        // that the .DS_Store file will mess up the calculated hash
        // We must skip this file.
        if ([fileName isEqualToString:@".DS_Store"]) {
            continue;
        }
#endif
        NSString *fullFilePath = [folderPath stringByAppendingPathComponent:fileName];
        NSString *relativePath = [pathPrefix stringByAppendingPathComponent:fileName];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:fullFilePath
                                                 isDirectory:&isDir] && isDir) {
            [self addContentsOfFolderToManifest:fullFilePath
                                     pathPrefix:relativePath
                                       manifest:manifest
                                          error:error];
            if (*error) {
                return;
            }
        } else {
            NSData *fileContents = [NSData dataWithContentsOfFile:fullFilePath];
            NSString *fileContentsHash = [self computeHashForData:fileContents];
            [manifest addObject:[[relativePath stringByAppendingString:@":"] stringByAppendingString:fileContentsHash]];
        }
    }
}

+ (void)addFileToManifest:(NSURL *)fileURL
                 manifest:(NSMutableArray *)manifest
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
        NSData *fileContents = [NSData dataWithContentsOfURL:fileURL];
        NSString *fileContentsHash = [self computeHashForData:fileContents];
        [manifest addObject:[NSString stringWithFormat:@"%@/%@:%@", [self manifestFolderPrefix], [fileURL lastPathComponent], fileContentsHash]];
    }
}

+ (NSString *)computeFinalHashFromManifest:(NSMutableArray *)manifest
                                     error:(NSError **)error
{
    NSArray *sortedManifest = [manifest sortedArrayUsingSelector:@selector(compare:)];
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:sortedManifest
                                                           options:kNilOptions
                                                             error:error];
    if (*error) {
        return nil;
    }
    
    NSString *manifestString = [[NSString alloc] initWithData:manifestData
                                                     encoding:NSUTF8StringEncoding];
    // The JSON serialization turns path separators into "\/", e.g. "CodePush\/assets\/image.png"
    manifestString = [manifestString stringByReplacingOccurrencesOfString:@"\\/"
                                                               withString:@"/"];
    return [self computeHashForData:[NSData dataWithBytes:manifestString.UTF8String length:manifestString.length]];
}

+ (NSString *)computeHashForData:(NSData *)inputData
{
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(inputData.bytes, inputData.length, digest);
    NSMutableString* inputHash = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [inputHash appendFormat:@"%02x", digest[i]];
    }
    
    return inputHash;
}

+ (void)copyEntriesInFolder:(NSString *)sourceFolder
                 destFolder:(NSString *)destFolder
                      error:(NSError **)error
{
    NSArray* files = [[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:sourceFolder
                      error:error];
    if (*error) {
        return;
    }
    
    for (NSString *fileName in files) {
        NSString * fullFilePath = [sourceFolder stringByAppendingPathComponent:fileName];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:fullFilePath
                                                 isDirectory:&isDir] && isDir) {
            NSString *nestedDestFolder = [destFolder stringByAppendingPathComponent:fileName];
            [self copyEntriesInFolder:fullFilePath
                           destFolder:nestedDestFolder
                                error:error];
        } else {
            NSString *destFileName = [destFolder stringByAppendingPathComponent:fileName];
            if ([[NSFileManager defaultManager] fileExistsAtPath:destFileName]) {
                [[NSFileManager defaultManager] removeItemAtPath:destFileName error:error];
                if (*error) {
                    return;
                }
            }
            if (![[NSFileManager defaultManager] fileExistsAtPath:destFolder]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:destFolder
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:error];
                if (*error) {
                    return;
                }
            }
            
            [[NSFileManager defaultManager] copyItemAtPath:fullFilePath toPath:destFileName error:error];
            if (*error) {
                return;
            }
        }
    }
}

+ (NSString *)findMainBundleInFolder:(NSString *)folderPath
                    expectedFileName:(NSString *)expectedFileName
                               error:(NSError **)error
{
    NSArray* folderFiles = [[NSFileManager defaultManager]
                            contentsOfDirectoryAtPath:folderPath
                            error:error];
    if (*error) {
        return nil;
    }
    
    for (NSString *fileName in folderFiles) {
        NSString *fullFilePath = [folderPath stringByAppendingPathComponent:fileName];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:fullFilePath
                                                 isDirectory:&isDir] && isDir) {
            NSString *mainBundlePathInFolder = [self findMainBundleInFolder:fullFilePath
                                                           expectedFileName:expectedFileName
                                                                      error:error];
            if (*error) {
                return nil;
            }
            
            if (mainBundlePathInFolder) {
                return [fileName stringByAppendingPathComponent:mainBundlePathInFolder];
            }
        } else if ([fileName isEqualToString:expectedFileName]) {
            return fileName;
        }
    }
    
    return nil;
}

+ (NSString *)assetsFolderName
{
    return AssetsFolderName;
}

+ (NSString *)getHashForBinaryContents:(NSURL *)binaryBundleUrl
                                 error:(NSError **)error
{
    // Get the cached hash from user preferences if it exists.
    NSString *binaryModifiedDate = [self modifiedDateStringOfFileAtURL:binaryBundleUrl];
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *binaryHashDictionary = [preferences objectForKey:BinaryHashKey];
    NSString *binaryHash = nil;
    if (binaryHashDictionary != nil) {
        binaryHash = [binaryHashDictionary objectForKey:binaryModifiedDate];
        if (binaryHash == nil) {
            [preferences removeObjectForKey:BinaryHashKey];
            [preferences synchronize];
        } else {
            return binaryHash;
        }
    }
    
    binaryHashDictionary = [NSMutableDictionary dictionary];
    NSMutableArray *manifest = [NSMutableArray array];
    
    // If the app is using assets, then add
    // them to the generated content manifest.
    NSString *assetsPath = [CodePush bundleAssetsPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:assetsPath]) {
        [self addContentsOfFolderToManifest:assetsPath
                                 pathPrefix:[NSString stringWithFormat:@"%@/%@", [self manifestFolderPrefix], @"assets"]
                                   manifest:manifest
                                      error:error];
        if (*error) {
            return nil;
        }
    }
    
    [self addFileToManifest:binaryBundleUrl manifest:manifest];
    [self addFileToManifest:[binaryBundleUrl URLByAppendingPathExtension:@"meta"] manifest:manifest];

    binaryHash = [self computeFinalHashFromManifest:manifest error:error];
    
    // Cache the hash in user preferences. This assumes that the modified date for the
    // JS bundle changes every time a new bundle is generated by the packager.
    [binaryHashDictionary setObject:binaryHash forKey:binaryModifiedDate];
    [preferences setObject:binaryHashDictionary forKey:BinaryHashKey];
    [preferences synchronize];
    return binaryHash;
}

+ (NSString *)manifestFolderPrefix
{
    return ManifestFolderPrefix;
}

+ (NSString *)modifiedDateStringOfFileAtURL:(NSURL *)fileURL
{
    if (fileURL != nil) {
        NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[fileURL path] error:nil];
        NSDate *modifiedDate = [fileAttributes objectForKey:NSFileModificationDate];
        return [NSString stringWithFormat:@"%f", [modifiedDate timeIntervalSince1970]];
    } else {
        return nil;
    }
}

+ (BOOL)verifyHashForDiffUpdate:(NSString *)finalUpdateFolder
                   expectedHash:(NSString *)expectedHash
                          error:(NSError **)error
{
    NSMutableArray *updateContentsManifest = [NSMutableArray array];
    [self addContentsOfFolderToManifest:finalUpdateFolder
                             pathPrefix:@""
                               manifest:updateContentsManifest
                                  error:error];
    if (*error) {
        return NO;
    }
    
    NSString *updateContentsManifestHash = [self computeFinalHashFromManifest:updateContentsManifest
                                                                        error:error];
    if (*error || updateContentsManifestHash == nil) {
        return NO;
    }
    
    return [updateContentsManifestHash isEqualToString:expectedHash];
}

@end