#+build windows
package ipc

import "core:strings"
import win "core:sys/windows"
import "core:testing"


@(private = "file")
SE_KERNEL_OBJECT :: 6

@(private = "file")
DACL_SECURITY_INFORMATION :: 0x4

foreign import advapi32_test "system:Advapi32.lib"

@(private = "file", default_calling_convention = "system")
foreign advapi32_test {
	GetSecurityInfo :: proc(
		handle: win.HANDLE,
		ObjectType: i32,
		SecurityInfo: win.DWORD,
		ppsidOwner, ppsidGroup: ^rawptr,
		ppDacl, ppSacl: ^rawptr,
		ppSecurityDescriptor: ^rawptr,
	) -> win.DWORD ---
	ConvertSecurityDescriptorToStringSecurityDescriptorW :: proc(
		SecurityDescriptor: rawptr,
		RequestedStringSDRevision: win.DWORD,
		SecurityInformation: win.DWORD,
		StringSecurityDescriptor: ^win.LPWSTR,
		StringSecurityDescriptorLen: ^win.ULONG,
	) -> win.BOOL ---
}


// The pipe's DACL, read back from the pipe: one entry, for the current user,
// none inherited (the default one lets everyone and anonymous read)
@(test)
test_pipe_only_for_user :: proc(t: ^testing.T) {
	s: Server
	testing.expect(t, server_start(&s, nil, nil))
	defer server_stop(&s)

	descriptor: rawptr
	dacl: rawptr
	err := GetSecurityInfo(
		s.pipe,
		SE_KERNEL_OBJECT,
		DACL_SECURITY_INFORMATION,
		nil,
		nil,
		&dacl,
		nil,
		&descriptor,
	)
	testing.expect_value(t, err, 0)
	defer win.LocalFree(descriptor)

	wide: win.LPWSTR
	converted := ConvertSecurityDescriptorToStringSecurityDescriptorW(
		descriptor,
		1,
		DACL_SECURITY_INFORMATION,
		&wide,
		nil,
	)
	testing.expect(t, bool(converted))
	defer win.LocalFree(wide)
	sddl, _ := win.wstring_to_utf8(win.wstring(wide), -1, context.temp_allocator)

	testing.expectf(t, strings.has_prefix(sddl, "D:P("), "not protected: %s", sddl)
	testing.expectf(t, strings.count(sddl, "(") == 1, "more than one entry: %s", sddl)
	testing.expectf(t, strings.contains(sddl, ";;;S-1-5-"), "not a user's SID: %s", sddl)
}
