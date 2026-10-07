### Fixed

- **The Leaf comment check catches function tags and CSS comments.** It caught only the interpolation and the structural tags inside an HTML comment. Leaf also runs a function tag with parameters there, and it reads a CSS comment in a page `<style>` block as plain text too. There were no such tags. (#2407)
