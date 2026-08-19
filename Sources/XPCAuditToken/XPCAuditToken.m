#import "XPCAuditToken.h"

// NSXPCConnection exposes the peer's audit token via a private (but stable,
// long-used) property. Declare it so we can read it; wrap defensively in case a
// future OS removes it.
@interface NSXPCConnection (SidePulsePrivateAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

NSData *SidePulseAuditToken(NSXPCConnection *connection) {
    if (![connection respondsToSelector:@selector(auditToken)]) {
        return nil;
    }
    @try {
        audit_token_t token = connection.auditToken;
        return [NSData dataWithBytes:&token length:sizeof(token)];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}
