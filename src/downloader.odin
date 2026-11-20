package zemu

// Core downloader: lists the cores on the libretro buildbot for this
// platform, installs them, and keeps the .info files (names, systems,
// extensions) up to date.

import "core:fmt"
import "core:slice"
import "core:strings"

BUILDBOT_URL  :: "https://buildbot.libretro.com/nightly/"
CORE_INFO_URL :: "https://buildbot.libretro.com/assets/frontend/info.zip"

// Where this platform's cores live on the buildbot ("" when there are none).
buildbot_dir :: proc() -> string {
	when IS_ANDROID {
		when ODIN_ARCH == .arm64 do return "android/latest/arm64-v8a/"
		else when ODIN_ARCH == .arm32 do return "android/latest/armeabi-v7a/"
		else when ODIN_ARCH == .amd64 do return "android/latest/x86_64/"
		else do return "android/latest/x86/"
	} else when ODIN_OS == .Windows {
		return "windows/x86_64/latest/" when ODIN_ARCH == .amd64 else "windows/x86/latest/"
	} else when ODIN_OS == .Darwin {
		return "apple/osx/arm64/latest/" when ODIN_ARCH == .arm64 else "apple/osx/x86_64/latest/"
	} else when ODIN_OS == .Linux {
		when ODIN_ARCH == .arm64 do return "linux/aarch64/latest/"
		else when ODIN_ARCH == .arm32 do return "linux/armhf/latest/"
		else do return "linux/x86_64/latest/"
	} else {
		return ""
	}
}

Remote_Core :: struct {
	file:       string, // "snes9x_libretro.so.zip"
	lib:        string, // "snes9x_libretro.so"
	id:         string, // "snes9x"
	name:       string,
	system:     string,
	extensions: string,
	date:       string,
}

Catalog_State :: enum u8 {
	Empty,
	Loading,
	Ready,
	Failed,
}

Downloader :: struct {
	state:     Catalog_State,
	index_req: ^Http_Request,
	info_req:  ^Http_Request,
	remote:    [dynamic]Remote_Core,

	job:       ^Http_Request,
	job_core:  int,
	queue:     [dynamic]int,
	done_count: int,
	failed:    string,
}

dl: Downloader

downloads_supported :: proc() -> bool {
	return buildbot_base_url() != ""
}

buildbot_base_url :: proc() -> string {
	when IS_WEB {
		return web_cores_base_url()
	} else {
		dir := buildbot_dir()
		if dir == "" do return ""
		return strings.concatenate({BUILDBOT_URL, dir}, context.temp_allocator)
	}
}

// Fetch the core list and the info files.
catalog_refresh :: proc() {
	// Downloads hold indices into dl.remote, which a refresh rebuilds.
	if dl.state == .Loading || download_busy() do return
	base := buildbot_base_url()
	if base == "" {
		dl.state = .Failed
		return
	}
	dl.state = .Loading
	http_free(dl.index_req)
	http_free(dl.info_req)
	dl.index_req = http_get(strings.concatenate({base, ".index-extended"}, context.temp_allocator), join_path(paths.info, "index.txt", context.temp_allocator))
	// The web build can't read the buildbot (no CORS), so the site mirrors info.zip.
	info_url := strings.concatenate({base, "info.zip"}, context.temp_allocator) if IS_WEB else CORE_INFO_URL
	dl.info_req = http_get(info_url, join_path(paths.info, "info.zip", context.temp_allocator))
}

// Called every frame.
downloader_update :: proc() {
	if dl.state == .Loading {
		http_poll(dl.index_req)
		http_poll(dl.info_req)
		if dl.index_req.state != .Running && dl.info_req.state != .Running {
			if dl.info_req.state == .Done {
				info_zip_install(dl.info_req.dest)
				catalog_exts_loaded = false // re-read on next use
			}
			if dl.index_req.state == .Done {
				catalog_parse(dl.index_req.dest)
				dl.state = .Ready
				cores_scan() // pick up names from fresh .info files
			} else {
				dl.state = .Failed
			}
			http_free(dl.index_req); dl.index_req = nil
			http_free(dl.info_req); dl.info_req = nil
		}
	}

	if dl.job != nil {
		http_poll(dl.job)
		if dl.job.state != .Running {
			rc := &dl.remote[dl.job_core]
			if dl.job.state == .Done && core_install_zip(dl.job.dest, rc.lib) {
				dl.done_count += 1
				osd_message(fmt.tprintf("INSTALLED %s", rc.id))
			} else {
				delete(dl.failed)
				dl.failed = strings.clone(rc.id)
				osd_message(fmt.tprintf("DOWNLOAD FAILED: %s", rc.id))
			}
			_ = delete_file(dl.job.dest)
			http_free(dl.job)
			dl.job = nil
			cores_scan()
		}
	}
	if dl.job == nil && len(dl.queue) > 0 {
		i := pop_front(&dl.queue)
		rc := dl.remote[i]
		url := strings.concatenate({buildbot_base_url(), rc.file}, context.temp_allocator)
		dl.job_core = i
		dl.job = http_get(url, join_path(paths.cores, strings.concatenate({rc.file, ".part"}, context.temp_allocator), context.temp_allocator))
	}
}

download_core :: proc(i: int) {
	if i < 0 || i >= len(dl.remote) do return
	if dl.job != nil && dl.job_core == i do return
	for q in dl.queue do if q == i do return
	append(&dl.queue, i)
}

download_busy :: proc() -> bool {
	return dl.job != nil || len(dl.queue) > 0
}

// Re-download every installed core that the buildbot has.
update_all_cores :: proc() {
	for e in installed_cores {
		lib := base_name(e.path)
		for rc, i in dl.remote do if rc.lib == lib do download_core(i)
	}
}

remote_installed :: proc(rc: Remote_Core) -> bool {
	return file_exists(join_path(paths.cores, rc.lib, context.temp_allocator))
}

core_install_zip :: proc(zip_path, lib: string) -> bool {
	data, ok := read_file(zip_path, context.temp_allocator)
	if !ok do return false
	bin, ok2 := zip_extract_first(data, context.temp_allocator)
	if !ok2 do return false
	dest := join_path(paths.cores, lib, context.temp_allocator)
	// Replacing the running core: unload it first, it is mapped in memory.
	if core_loaded && core.path == dest do core_unload()
	tmp := strings.concatenate({dest, ".new"}, context.temp_allocator)
	if !write_file(tmp, bin) do return false
	_ = delete_file(dest)
	return rename_file(tmp, dest)
}

info_zip_install :: proc(zip_path: string) {
	data, ok := read_file(zip_path)
	if !ok do return
	defer delete(data)
	entries, ok2 := zip_entries(data, context.temp_allocator)
	if !ok2 do return
	for e in entries {
		if !strings.has_suffix(e.name, ".info") do continue
		if out, ok3 := zip_extract(data, e, context.temp_allocator); ok3 {
			_ = write_file(join_path(paths.info, base_name(e.name), context.temp_allocator), out)
		}
	}
	_ = delete_file(zip_path)
}

catalog_clear :: proc() {
	for rc in dl.remote {
		delete(rc.file); delete(rc.lib); delete(rc.id); delete(rc.name)
		delete(rc.system); delete(rc.extensions); delete(rc.date)
	}
	clear(&dl.remote)
}

catalog_parse :: proc(index_path: string) {
	catalog_clear()
	data, ok := read_file(index_path, context.temp_allocator)
	if !ok do return
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 3 do continue
		file := fields[len(fields) - 1]
		if !strings.has_suffix(file, ".zip") do continue
		lib := file[:len(file) - 4]
		id := core_id_from_file(lib)
		rc := Remote_Core{
			file = strings.clone(file),
			lib  = strings.clone(lib),
			id   = strings.clone(id),
			date = strings.clone(fields[0]),
		}
		if info, ok2 := core_info_read(id); ok2 {
			rc.name       = short_core_name(info.display_name, context.allocator)
			rc.system     = strings.clone(info.system)
			rc.extensions = strings.clone(info.extensions)
		}
		if rc.name == "" do rc.name = strings.clone(id)
		append(&dl.remote, rc)
	}
	slice.sort_by(dl.remote[:], proc(a, b: Remote_Core) -> bool {
		return strings.compare(strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)) < 0
	})
}

// Search matches the name, the system and the file extensions.
remote_matches :: proc(rc: Remote_Core, query: string) -> bool {
	if query == "" do return true
	q := strings.to_lower(query, context.temp_allocator)
	if strings.contains(strings.to_lower(rc.name, context.temp_allocator), q) do return true
	if strings.contains(strings.to_lower(rc.system, context.temp_allocator), q) do return true
	exts := rc.extensions
	for e in strings.split_iterator(&exts, "|") {
		if strings.equal_fold(e, query) do return true
	}
	return false
}
