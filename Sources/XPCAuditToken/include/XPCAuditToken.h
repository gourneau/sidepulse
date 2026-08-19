#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the kernel audit token of an NSXPCConnection wrapped as NSData
/// (sizeof(audit_token_t) bytes), or nil if unavailable. The audit token
/// identifies the peer process unforgeably — unlike its PID, it cannot be
/// reused by a different process, so it's the correct basis for code-signing
/// validation of an XPC client.
NSData * _Nullable SidePulseAuditToken(NSXPCConnection *connection);

NS_ASSUME_NONNULL_END
