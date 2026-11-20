#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVAudioEngine and AVAudioNode report several misuses (a tap whose format
/// no longer matches the device, a graph that cannot be connected) by raising
/// an Objective-C exception instead of returning an error. Swift cannot catch
/// one: it unwinds every Swift frame above it without running a single catch,
/// defer or assignment, and AppKit swallows it at the run loop. This turns
/// the exception into an ordinary NSError at the call site.
@interface AmanuObjCExceptionCatcher : NSObject
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
