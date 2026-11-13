### Security

- **Section delete in the suite editor checks the form target.** The delete button's `data-action` must resolve to a same-origin path before it becomes a form target. The check is now one shared helper, `ChickadeeUI.sameOriginURL`, used by the suite editor and the assignments page. This closes CodeQL alert 24 (js/xss-through-dom).
