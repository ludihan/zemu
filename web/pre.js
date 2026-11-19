// Runs before the app starts (linked with --pre-js).
// SDL keeps the data folder under /libsdl; back it with IndexedDB so saves,
// settings, games and cores survive reloads.

Module.preRun = Module.preRun || [];
Module.preRun.push(function () {
	FS.mkdir('/libsdl');
	FS.mount(IDBFS, {}, '/libsdl');
	addRunDependency('zemu-syncfs');
	FS.syncfs(true, function (err) {
		if (err) console.warn('zemu: could not load saved data', err);
		removeRunDependency('zemu-syncfs');
	});
});

// Writes are batched: persist a second after the last change.
Module.zemuFsDirty = (function () {
	let timer = null;
	return function () {
		if (timer) clearTimeout(timer);
		timer = setTimeout(function () {
			timer = null;
			FS.syncfs(false, function (err) {
				if (err) console.warn('zemu: could not save data', err);
			});
		}, 1000);
	};
})();

// Files dropped on the page go into the games folder (cores into cores/).
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', async (e) => {
	e.preventDefault();
	for (const f of e.dataTransfer.files) {
		const dir = f.name.endsWith('.wasm') ? '/libsdl/zemu/zemu/cores/' : '/libsdl/zemu/zemu/roms/';
		FS.writeFile(dir + f.name, new Uint8Array(await f.arrayBuffer()));
	}
	Module.zemuImportCount = (Module.zemuImportCount | 0) + 1;
	Module.zemuFsDirty();
});
