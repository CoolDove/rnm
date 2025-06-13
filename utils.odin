package main

import "core:strings"

import win32 "core:sys/windows"

@(deferred_out=strings.builder_destroy, require_results)
scoped_strbdr :: proc () -> ^strings.Builder {
	sb := new(strings.Builder, context.temp_allocator)
	strings.builder_init(sb)
	return sb
}
