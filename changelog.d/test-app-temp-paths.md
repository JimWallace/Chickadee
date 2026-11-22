### Fixed

- **Test apps no longer write state files into the checkout.** `makeTestApp` now puts the alert webhook file, the LTI tool key and the GitHub App secrets file in its per-app temporary directory, like the worker secret. Before, a test that saved the alert webhook wrote or removed `.alert-webhook-url` in the repository.
