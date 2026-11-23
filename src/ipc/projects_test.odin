package ipc

import "core:strings"
import "core:testing"


// A project's name doesn't depend on how its folder is written (case on
// Windows, a trailing separator), and different folders get different names
@(test)
test_project_name :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		a := project_name(`C:\Work\App`)
		b := project_name(`c:\work\app\`)
		c := project_name(`C:\Work\Other`)
	} else {
		a := project_name("/work/app")
		b := project_name("/work/app/")
		c := project_name("/work/other")
	}

	testing.expect(t, strings.has_prefix(a, PROJECT_PREFIX))
	testing.expect_value(t, len(a), len(PROJECT_PREFIX) + 16)
	testing.expect_value(t, a, b)
	testing.expect(t, a != c)
}


// A window's endpoint is found under its project until it is taken off; a
// stale entry can be forgotten; names typo didn't make are refused
@(test)
test_project_registry :: proc(t: ^testing.T) {
	name := project_name("typo-registry-test-folder")
	endpoint := "endpoint-for-the-test"
	if !project_register(name, endpoint) {
		testing.fail_now(t, "the registry can't be written")
	}

	listed := project_endpoints(name)
	testing.expect_value(t, len(listed), 1)
	if len(listed) == 1 do testing.expect_value(t, listed[0], endpoint)

	project_forget(name, endpoint)
	testing.expect_value(t, len(project_endpoints(name)), 0)

	testing.expect(t, project_register(name, endpoint))
	project_unregister(name)
	testing.expect_value(t, len(project_endpoints(name)), 0)

	// Only names project_name makes reach the file system
	testing.expect(t, !project_register(`project:..\..\x`, endpoint))
	testing.expect(t, !project_register("other:0123456789abcdef", endpoint))
}
