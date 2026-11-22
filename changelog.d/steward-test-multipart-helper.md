### Changed

- **One multipart form helper in the API tests.** The private multipart body builders in five test files now call the shared `arMultipartBody`, and the repeated POSTs of a multipart form and of the student upload form now go through the new shared `postMultipartForm` and `wrPostSubmitUpload`. Each request keeps the same parts in the same order, and each test checks the same results.
