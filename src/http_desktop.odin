#+build !js
package zemu

import "core:c"
import sdl "vendor:sdl3"

when !IS_ANDROID {

Http_Impl :: struct {
	process: ^sdl.Process,
}

CURL_EXE :: "curl.exe" when ODIN_OS == .Windows else "curl"

http_impl_start :: proc(r: ^Http_Request) -> bool {
	_ = delete_file(r.dest)
	args := [?]cstring{
		CURL_EXE, "-fsSL", "--retry", "2", "--connect-timeout", "20",
		"-o", tcstr(r.dest), tcstr(r.url), nil,
	}
	r.impl.process = sdl.CreateProcess(raw_data(args[:]), false)
	return r.impl.process != nil
}

http_impl_poll :: proc(r: ^Http_Request) {
	info: sdl.PathInfo
	if sdl.GetPathInfo(tcstr(r.dest), &info) do r.bytes = i64(info.size)
	code: c.int
	if sdl.WaitProcess(r.impl.process, false, &code) {
		r.state = .Done if code == 0 else .Failed
		sdl.DestroyProcess(r.impl.process)
		r.impl.process = nil
	}
}

http_impl_free :: proc(r: ^Http_Request) {
	if r.impl.process != nil {
		_ = sdl.KillProcess(r.impl.process, true)
		sdl.DestroyProcess(r.impl.process)
	}
}

}
