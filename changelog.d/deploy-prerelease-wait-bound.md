### Fixed

- **An approved pre-release with no image no longer holds production's deploys.** If the image of an rc approved on the Deployment page is still not deployable after two hours, production's deployer drops the approval, records `approve expired` in the deploy history, and deploys releases as usual. The rc stays offered on the Coming next card, so an admin can approve it again once its image exists.
