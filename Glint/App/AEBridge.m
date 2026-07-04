// One ObjC shim: `NSAppleEventDescriptor.descriptorAtIndex:` isn't bridged to
// Swift on the current SDK, and `perform(_:with:)`/`NSInvocation` can't pass a
// primitive NSInteger index. This is the clean way around it — a plain C entry
// point the Swift side reaches through the bridging header. See
// AppDelegate.descriptorList / glint_aeDescriptorAtIndex.

#import "Glint-Bridging-Header.h"

NSAppleEventDescriptor *glint_aeDescriptorAtIndex(NSAppleEventDescriptor *list, NSInteger index) {
    return [list descriptorAtIndex:index];
}
