#+build linux
package zemu

// Android downloads: ZemuActivity.download() fetches the URL on a Java
// thread with HttpURLConnection and drops "<dest>.ok" or "<dest>.err" when it
// finishes, which we poll for. One JNI call, made from SDL's main thread
// (a Java thread, so FindClass sees the app's classes).

import "core:strings"
import sdl "vendor:sdl3"

when IS_ANDROID {

Http_Impl :: struct {
	ok_marker:  string,
	err_marker: string,
}

// Indices into the JNINativeInterface function table (jni.h).
@(private="file") JNI_FIND_CLASS          :: 6
@(private="file") JNI_EXCEPTION_CLEAR     :: 17
@(private="file") JNI_DELETE_LOCAL_REF    :: 23
@(private="file") JNI_GET_STATIC_METHOD   :: 113
@(private="file") JNI_CALL_STATIC_VOID_A  :: 143
@(private="file") JNI_NEW_STRING_UTF      :: 167
@(private="file") JNI_EXCEPTION_CHECK     :: 228

@(private="file")
jni :: proc(env: rawptr, index: int) -> rawptr {
	return (^[^]rawptr)(env)^[index]
}

http_impl_start :: proc(r: ^Http_Request) -> bool {
	r.impl.ok_marker = strings.concatenate({r.dest, ".ok"})
	r.impl.err_marker = strings.concatenate({r.dest, ".err"})
	_ = delete_file(r.dest)
	_ = delete_file(r.impl.ok_marker)
	_ = delete_file(r.impl.err_marker)

	env := sdl.GetAndroidJNIEnv()
	if env == nil do return false

	Find_Class      :: #type proc "c" (env: rawptr, name: cstring) -> rawptr
	Get_Static      :: #type proc "c" (env: rawptr, cls: rawptr, name, sig: cstring) -> rawptr
	Call_Static_A   :: #type proc "c" (env: rawptr, cls: rawptr, method: rawptr, args: [^]u64)
	New_String_UTF  :: #type proc "c" (env: rawptr, s: cstring) -> rawptr
	Delete_Local    :: #type proc "c" (env: rawptr, obj: rawptr)
	Exception_Check :: #type proc "c" (env: rawptr) -> u8
	Exception_Clear :: #type proc "c" (env: rawptr)

	check :: proc(env: rawptr) -> bool {
		if (Exception_Check)(jni(env, JNI_EXCEPTION_CHECK))(env) != 0 {
			(Exception_Clear)(jni(env, JNI_EXCEPTION_CLEAR))(env)
			return false
		}
		return true
	}

	cls := (Find_Class)(jni(env, JNI_FIND_CLASS))(env, "dev/zemu/libretro/ZemuActivity")
	if cls == nil || !check(env) do return false
	defer (Delete_Local)(jni(env, JNI_DELETE_LOCAL_REF))(env, cls)

	method := (Get_Static)(jni(env, JNI_GET_STATIC_METHOD))(env, cls, "download", "(Ljava/lang/String;Ljava/lang/String;)V")
	if method == nil || !check(env) do return false

	new_str := (New_String_UTF)(jni(env, JNI_NEW_STRING_UTF))
	jurl := new_str(env, tcstr(r.url))
	jdest := new_str(env, tcstr(r.dest))
	// jvalue is an 8 byte union; object references go in the low bytes.
	args := [2]u64{u64(uintptr(jurl)), u64(uintptr(jdest))}
	(Call_Static_A)(jni(env, JNI_CALL_STATIC_VOID_A))(env, cls, method, raw_data(args[:]))
	ok := check(env)
	(Delete_Local)(jni(env, JNI_DELETE_LOCAL_REF))(env, jurl)
	(Delete_Local)(jni(env, JNI_DELETE_LOCAL_REF))(env, jdest)
	return ok
}

http_impl_poll :: proc(r: ^Http_Request) {
	info: sdl.PathInfo
	if sdl.GetPathInfo(tcstr(r.dest), &info) do r.bytes = i64(info.size)
	if file_exists(r.impl.ok_marker) {
		r.state = .Done
	} else if file_exists(r.impl.err_marker) {
		r.state = .Failed
	}
}

http_impl_free :: proc(r: ^Http_Request) {
	_ = delete_file(r.impl.ok_marker)
	_ = delete_file(r.impl.err_marker)
	delete(r.impl.ok_marker)
	delete(r.impl.err_marker)
}

}
