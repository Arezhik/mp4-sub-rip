#import "CaptionExceptionBox.h"

NSString * _Nullable MP4SubRipCatch(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *name = exception.name.length > 0 ? exception.name : @"NSException";
        NSString *reason = exception.reason;
        if (reason.length == 0) {
            return name;
        }
        return [NSString stringWithFormat:@"%@: %@", name, reason];
    }
}
