### Changed

- **Large kernel files go out as brotli copies made at image build.** A new
  Dockerfile stage writes a brotli copy (quality 9) of each `.wasm`, `.js` and
  `.so` file over 64 KB in the vendored xeus tree, with the original's mtime.
  The server sends the copy to a browser that accepts `br`, so it no longer
  gzips up to 27 MB per request, and the transfer is 13 to 28% smaller than
  gzip -9: `liboctinterp.so` 27.2 MB to 5.0 MB, `xpython.wasm` 15.0 MB to
  4.4 MB. A client without `br` and a `Range` request get the file as before.
