package zemu

// Asynchronous downloads to a file. Each platform provides the transfer:
//   desktop: the system curl (shipped with Windows 10+, macOS and Linux)
//   Android: java.net.HttpURLConnection through JNI
//   web:     the browser's fetch()

import "core:strings"

Http_State :: enum u8 {
	Running,
	Done,
	Failed,
}

Http_Request :: struct {
	url:   string,
	dest:  string,
	state: Http_State,
	bytes: i64, // downloaded so far, when known
	total: i64, // expected size, 0 if unknown
	impl:  Http_Impl,
}

http_get :: proc(url, dest: string) -> ^Http_Request {
	r := new(Http_Request)
	r.url = strings.clone(url)
	r.dest = strings.clone(dest)
	r.state = .Running
	if !http_impl_start(r) do r.state = .Failed
	return r
}

http_poll :: proc(r: ^Http_Request) {
	if r == nil || r.state != .Running do return
	http_impl_poll(r)
}

http_free :: proc(r: ^Http_Request) {
	if r == nil do return
	http_impl_free(r)
	delete(r.url)
	delete(r.dest)
	free(r)
}
