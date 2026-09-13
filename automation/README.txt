These workflow examples are not active GitHub Actions workflows.

The publishing credential can create repositories, releases, and Pages sites,
but cannot write .github/workflows without the additional workflow scope.
The website is therefore published from the gh-pages branch using GitHub's
built-in static Pages deployment, not a custom workflow.

After committing site changes, run scripts\publish-site.ps1 to update that
branch. The script uses a subtree of site\, not a second hand-maintained copy.
It never force-pushes. The local application and website checks are documented
in README.md and site\tests; no hosted CI result is implied by these examples.
