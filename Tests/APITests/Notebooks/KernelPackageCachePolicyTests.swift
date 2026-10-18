import Testing

@testable import APIServer
@testable import Core

/// Which fast-path files are served as immutable. A kernel package tarball is,
/// because each name maps to one set of bytes; the kernel's startup JSON and
/// anything outside a vendored `kernel_packages/` tree are not.
@Suite struct KernelPackageCachePolicyTests {
    @Test func everyVendoredKernelTreeServesItsTarballsAsImmutable() throws {
        let prefixes = EditorAssetFastPathMiddleware.vendoredKernelPackagePrefixes
        try #require(!prefixes.isEmpty)
        for prefix in prefixes {
            #expect(EditorAssetFastPathMiddleware.isImmutableKernelPackage(path: prefix + "numpy-2.5.1-py313h.tar.gz"))
            #expect(
                EditorAssetFastPathMiddleware.isImmutableKernelPackage(
                    path: prefix + "pyodide-http-0.2.2-pyhcf101f3_0.chickadee.d559a3a226f3.tar.gz"))
        }
    }

    @Test(arguments: [
        // Startup JSON and kernel binaries revalidate.
        "/jupyterlite/xeus/kernels.json",
        "/jupyterlite/xeus/chickadee-python/empack_env_meta.json",
        "/jupyterlite/xeus/chickadee-python/xpython/kernel.json",
        // A non-tarball inside the tree is not covered by the naming promise.
        "/jupyterlite/xeus/chickadee-python/kernel_packages/README.md",
        // A tree that no language vendors is not on the list.
        "/jupyterlite/xeus/chickadee-unknown/kernel_packages/numpy-2.5.1-py313h.tar.gz",
        // A tarball elsewhere is not a kernel package.
        "/vendor/numpy-2.5.1-py313h.tar.gz",
    ])
    func otherFilesAreNotImmutable(path: String) {
        #expect(!EditorAssetFastPathMiddleware.isImmutableKernelPackage(path: path))
    }
}
