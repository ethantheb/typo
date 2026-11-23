#+build darwin
package trash

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

// The Trash, through NSFileManager's trashItemAtURL, which puts the item in the
// Trash of its volume (Finder's "Put Back" knows where it came from)


@(private = "file", objc_class = "NSFileManager")
File_Manager :: struct {
	using _: NS.Object,
}

// The volume has no Trash (NSFeatureUnsupportedError)
@(private = "file")
FEATURE_UNSUPPORTED :: 3328


move :: proc(path: string) -> Result {
	NS.scoped_autoreleasepool()

	manager := intrinsics.objc_send(^File_Manager, File_Manager, "defaultManager")
	text := NS.String.alloc()->initWithOdinString(path)
	defer text->release()
	url := NS.URL.alloc()->initFileURLWithPath(text)
	defer url->release()

	failure: ^NS.Error
	moved := intrinsics.objc_send(
		NS.BOOL,
		manager,
		"trashItemAtURL:resultingItemURL:error:",
		url,
		rawptr(nil),
		&failure,
	)
	switch {
	case moved:
		return .Done
	case failure != nil && failure->code() == FEATURE_UNSUPPORTED:
		return .Not_Recyclable
	}
	return .Failed
}
