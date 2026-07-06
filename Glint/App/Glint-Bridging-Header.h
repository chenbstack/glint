#ifndef Glint_Bridging_Header_h
#define Glint_Bridging_Header_h

#import <Foundation/Foundation.h>

/// `-[NSAppleEventDescriptor descriptorAtIndex:]` isn't bridged to Swift on the
/// current SDK (its indexed-list access is missing from the Swift overlay), so
/// expose it via this one-line helper. Items are 1-indexed.
NSAppleEventDescriptor *glint_aeDescriptorAtIndex(NSAppleEventDescriptor *list, NSInteger index);

#endif /* Glint_Bridging_Header_h */
