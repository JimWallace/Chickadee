### Changed

- **Two more pages refresh through the shared poller.** The account page's data-export state and the live header of the admin runner page are regions that `table-poll.js` refreshes from a server fragment. The two private pollers are gone. The export poll now stops while the tab is hidden and lets an idle session expire. The runner page now also refreshes its status counts and facts. `scripts/check-ui-vocabulary.sh` fails on a new private poller in `Public/*.js` (#3007).
