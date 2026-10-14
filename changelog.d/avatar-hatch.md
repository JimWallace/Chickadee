### Added

- **Hatch a new bird.** The account page's bird card can draw a fresh bird, 3 times per term. A hatch always gives a different species; the backdrop, the ring and every class handle stay. The previous bird is kept, and "Go back to my …" restores it until the next hatch (a go back does not give the hatch back). With none left, the button stays disabled and says when the next term starts. Each hatch is a row in the new `avatar_hatches` table, and the bird before the last hatch is in `users.avatar_previous_spec`; both are in the data export and go with the account.
