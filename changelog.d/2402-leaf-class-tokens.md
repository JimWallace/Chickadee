### Fixed

- **The class-resolution check reads class names written against a Leaf tag.** A name such as `row#if(x): row-pending#endif` used to be dropped together with the tag, so it was never checked. Two roster hooks that had no rule now carry the `js-` prefix. (#2402)
