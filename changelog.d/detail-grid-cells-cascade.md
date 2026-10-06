### Fixed

- **Facts panels on the LTI, GitHub and runner pages.** The `.detail-grid--cells` rules came before the base `.detail-grid` rules in the stylesheet, so the base rules won. The panel was capped at 480px with one wide column and one very narrow column, and on the LTI page the URLs in the narrow column wrapped every few characters. The cell rules now come after the base rules, so the facts form an even grid.
