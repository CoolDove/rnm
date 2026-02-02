package main

import "base:runtime"
import "core:os/os2"
import "core:os"
import "core:fmt"
import "core:thread"
import "core:sync"

DynamicFileCollector :: struct {
	// After you call `file_collect_update`, this will be true until next `file_collect_update` call.
	changed : bool,
	files : [dynamic]string,

	_pool : [dynamic]string,

	_current_time : f64,
	// Maybe you can adjust this during running, but don't be less than 0.
	interval : f64,

	_lock : sync.Mutex,
	_thread : ^thread.Thread,
}

file_collect_init :: proc(using fc: ^DynamicFileCollector, _interval: f64, allocator:= context.allocator) {
	files = make_dynamic_array([dynamic]string)
	_pool = make_dynamic_array([dynamic]string)
	interval = _interval
	_thread = thread.create(_file_collect_work)
	_thread.user_args[0] = fc
	_thread.init_context = runtime.default_context()
}

file_collect_destroy :: proc(using fc: ^DynamicFileCollector) {
	delete(files)
	delete(_pool)
	if !thread.is_done(_thread) {
		thread.terminate(_thread, 0)
	}
	thread.destroy(_thread)
}

file_collect_begin :: proc(using fc: ^DynamicFileCollector) {
	thread.start(_thread)
}

file_collect_update :: proc(using fc: ^DynamicFileCollector, delta: f64) -> bool {
	if changed do changed = false

	_current_time += delta
	if _current_time >= interval {
		count := file_collect_pull(fc)
		changed = count > 0
		return true
	}
	return false
}

file_collect_pull :: proc(using fc: ^DynamicFileCollector) -> int {
	sync.mutex_guard(&_lock)
	count := len(_pool)
	for candidate in _pool {
		append(&files, candidate)
	}
	clear(&_pool)
	return count
}

@(private="file")
_file_collect_work :: proc(t: ^thread.Thread) {
	fc := cast(^DynamicFileCollector)t.user_args[0]
	root_path := os.get_current_directory(); defer delete(root_path)
	_ite_files(root_path, fc)
}

@(private="file")
_ite_files :: proc(path: string, fc: ^DynamicFileCollector) {
	fi, fierr := os2.stat(path, context.allocator)
	if fierr == nil {
		if fi.type == .Directory {
			files, err := os2.read_directory_by_path(fi.fullpath, 0, context.allocator) 
			if err == nil {
				for subf in files {
					_ite_files(subf.fullpath, fc)
				}
			}
			defer if err == nil {
				for subf in files {
					os2.file_info_delete(subf, context.allocator)
				}
				delete(files)
			}
		} else if fi.type == .Regular { // Maybe a normal file?
			sync.mutex_guard(&fc._lock)
			append(&fc._pool, fi.fullpath)
		}
	}
	defer os2.file_info_delete(fi, context.allocator)
}
