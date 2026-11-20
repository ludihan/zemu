#+build linux
package zemu

// Small Android helpers implemented in ZemuActivity.java, called over JNI
// from SDL's main thread (a Java thread, so FindClass sees the app's classes).

import "core:strings"
import sdl "vendor:sdl3"

when IS_ANDROID {

// Visible system bars + display cutout in pixels (left, top, right,
// bottom), sent by ZemuActivity whenever the window insets change. Written
// on Android's UI thread; a torn read only misplaces one frame.
android_visible_insets: [4]i32
android_have_visible_insets: bool

@(export, link_name = "Java_dev_zemu_libretro_ZemuActivity_nativeVisibleInsets")
android_native_visible_insets :: proc "c" (env, cls: rawptr, left, top, right, bottom: i32) {
	android_visible_insets = {left, top, right, bottom}
	android_have_visible_insets = true
}

// Indices into the JNINativeInterface function table (jni.h).
@(private="file") JNI_FIND_CLASS            :: 6
@(private="file") JNI_EXCEPTION_CLEAR       :: 17
@(private="file") JNI_DELETE_LOCAL_REF      :: 23
@(private="file") JNI_GET_STATIC_METHOD     :: 113
@(private="file") JNI_CALL_STATIC_OBJECT_A  :: 116
@(private="file") JNI_CALL_STATIC_VOID_A    :: 143
@(private="file") JNI_NEW_STRING_UTF        :: 167
@(private="file") JNI_GET_STRING_UTF_CHARS  :: 169
@(private="file") JNI_RELEASE_STRING_UTF    :: 170
@(private="file") JNI_EXCEPTION_CHECK       :: 228

@(private="file")
jni :: proc(env: rawptr, index: int) -> rawptr {
	return (^[^]rawptr)(env)^[index]
}

// The name the user sees for a content:// URI from the file picker
// (temp allocated). The URI itself often only holds an id.
android_display_name :: proc(uri: string) -> (name: string, ok: bool) {
	env := sdl.GetAndroidJNIEnv()
	if env == nil do return "", false

	Find_Class      :: #type proc "c" (env: rawptr, name: cstring) -> rawptr
	Get_Static      :: #type proc "c" (env: rawptr, cls: rawptr, name, sig: cstring) -> rawptr
	Call_Static_A   :: #type proc "c" (env: rawptr, cls: rawptr, method: rawptr, args: [^]u64) -> rawptr
	New_String_UTF  :: #type proc "c" (env: rawptr, s: cstring) -> rawptr
	Get_UTF_Chars   :: #type proc "c" (env: rawptr, s: rawptr, is_copy: ^u8) -> cstring
	Release_UTF     :: #type proc "c" (env: rawptr, s: rawptr, chars: cstring)
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
	del := (Delete_Local)(jni(env, JNI_DELETE_LOCAL_REF))

	cls := (Find_Class)(jni(env, JNI_FIND_CLASS))(env, "dev/zemu/libretro/ZemuActivity")
	if cls == nil || !check(env) do return "", false
	defer del(env, cls)
	method := (Get_Static)(jni(env, JNI_GET_STATIC_METHOD))(env, cls, "displayName", "(Ljava/lang/String;)Ljava/lang/String;")
	if method == nil || !check(env) do return "", false

	juri := (New_String_UTF)(jni(env, JNI_NEW_STRING_UTF))(env, tcstr(uri))
	defer del(env, juri)
	args := [1]u64{u64(uintptr(juri))}
	jname := (Call_Static_A)(jni(env, JNI_CALL_STATIC_OBJECT_A))(env, cls, method, raw_data(args[:]))
	if !check(env) || jname == nil do return "", false
	defer del(env, jname)

	chars := (Get_UTF_Chars)(jni(env, JNI_GET_STRING_UTF_CHARS))(env, jname, nil)
	if chars == nil do return "", false
	name = strings.clone(string(chars), context.temp_allocator)
	(Release_UTF)(jni(env, JNI_RELEASE_STRING_UTF))(env, jname, chars)
	return name, name != ""
}

// Hide the status and navigation bars (true) or show them (false). See
// ZemuActivity.setGameBars.
android_set_immersive :: proc(on: bool) {
	env := sdl.GetAndroidJNIEnv()
	if env == nil do return

	Find_Class      :: #type proc "c" (env: rawptr, name: cstring) -> rawptr
	Get_Static      :: #type proc "c" (env: rawptr, cls: rawptr, name, sig: cstring) -> rawptr
	Call_Static_A   :: #type proc "c" (env: rawptr, cls: rawptr, method: rawptr, args: [^]u64)
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
	if cls == nil || !check(env) do return
	defer (Delete_Local)(jni(env, JNI_DELETE_LOCAL_REF))(env, cls)
	method := (Get_Static)(jni(env, JNI_GET_STATIC_METHOD))(env, cls, "setGameBars", "(Z)V")
	if method == nil || !check(env) do return
	// jvalue is an 8 byte union; a jboolean is its low byte.
	args := [1]u64{1 if on else 0}
	(Call_Static_A)(jni(env, JNI_CALL_STATIC_VOID_A))(env, cls, method, raw_data(args[:]))
	_ = check(env)
}

}
