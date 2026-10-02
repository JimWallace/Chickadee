### Changed

- **A round-robin claim queries the classmate list once.** `jobOpponent` and `jobOpponents` each called `chooseClassmates` inside the serialized claim section; `jobOpponentSet` now chooses once and hands the list to both (#1750).
