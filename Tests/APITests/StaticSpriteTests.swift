import Testing
import VaporTesting

@testable import APIServer

/// Each static sprite reaches the pages, whether or not `loadSprites()` ran.
@Suite(.timeLimit(.minutes(1))) struct StaticSpriteTests {

    @Test(arguments: StaticSprite.allCases) func theSpriteIsReadWithOrWithoutTheCache(sprite: StaticSprite) async throws
    {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let uncached = app.sprite(sprite)
            #expect(uncached.contains("<symbol"))
            app.loadSprites()
            #expect(app.sprite(sprite) == uncached)
        }
    }
}
