// JS side of the web build (linked with --js-library).

addToLibrary({
	// Download url into the virtual file system, then drop a marker file.
	zemu_js_fetch__deps: ['$FS', '$UTF8ToString'],
	zemu_js_fetch: function (url, dest) {
		const u = UTF8ToString(url);
		const d = UTF8ToString(dest);
		fetch(u)
			.then((r) => {
				if (!r.ok) throw new Error('HTTP ' + r.status);
				return r.arrayBuffer();
			})
			.then((buf) => {
				FS.writeFile(d, new Uint8Array(buf));
				FS.writeFile(d + '.ok', '');
			})
			.catch((e) => {
				console.warn('zemu: download failed', u, e);
				try { FS.writeFile(d + '.err', ''); } catch (_) {}
			});
	},

	// Let the user pick files and copy them into dir.
	zemu_js_import__deps: ['$FS', '$UTF8ToString'],
	zemu_js_import: function (dir) {
		const d = UTF8ToString(dir);
		const input = document.createElement('input');
		input.type = 'file';
		input.multiple = true;
		input.onchange = async () => {
			for (const f of input.files) {
				FS.writeFile(d.replace(/\/$/, '') + '/' + f.name, new Uint8Array(await f.arrayBuffer()));
			}
			Module.zemuImportCount = (Module.zemuImportCount | 0) + 1;
			Module.zemuFsDirty();
		};
		input.click();
	},

	zemu_js_import_count: function () {
		return Module.zemuImportCount | 0;
	},

	zemu_js_fs_dirty: function () {
		Module.zemuFsDirty();
	},
});
