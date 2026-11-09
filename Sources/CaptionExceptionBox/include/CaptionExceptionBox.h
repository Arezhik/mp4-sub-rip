#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns nil, or the exception name and reason.
/// `AVAssetReaderOutputCaptionAdaptor` raises when a sample is not a caption
/// it understands. The extract has to log that and keep going.
NSString * _Nullable MP4SubRipCatch(void (NS_NOESCAPE ^ _Nonnull block)(void));

NS_ASSUME_NONNULL_END
