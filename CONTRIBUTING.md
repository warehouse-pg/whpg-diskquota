# Contributing

We warmly welcome and greatly appreciate contributions from the
community. By participating you agree to the [code of
conduct](https://github.com/warehouse-pg/whpg-diskquota/blob/main/CODE-OF-CONDUCT.md).
Overall, we follow WHPG's comprehensive contribution policy. Please
refer to it [here](https://github.com/warehouse-pg/warehouse-pg/blob/main/CONTRIBUTING.md)
for details.

## Getting Started

* Fork the `whpg-diskquota` repository on GitHub
* Clone the forked repository, so that `origin` points at your fork,
  and add this repository as `upstream`:
```
git remote add upstream https://github.com/warehouse-pg/whpg-diskquota.git
```
* Follow the README to set up your environment and run the tests

## Creating a change

* Create your own feature branch (e.g. `git checkout -b
  my_feature_branch`) and make changes on this branch.
* Try and follow similar coding styles as found throughout the code
  base, and format changed C code with clang-format 13 as described in
  the README.
* Make commits as logical units for ease of reviewing.
* Rebase on `upstream/main` often to stay in sync.
* Add or update tests to cover your code. Build with `cmake ..` and
  `make install` in a `build` directory against a WarehousePG
  installation whose `pg_config` is on your `PATH`, then run `make
  installcheck` there against a running WarehousePG demo cluster. The
  test suite changes the cluster configuration and restarts it, so do
  not run it against a cluster you care about. Regression tests live
  under [`tests/regress`](tests/regress) and
  [`tests/isolation2`](tests/isolation2).
* Keep changes working on every supported WarehousePG line (7 and
  19). Where a line produces different output, add an override to the
  matching `expected7` or `expected19` directory (e.g.
  `tests/regress/expected19/test_index.out`).
* Ensure a well written commit message as explained
  [here](https://chris.beams.io/posts/git-commit/).
* Push your local branch to your fork (e.g. `git push origin
  my_feature_branch`)

## Submitting a Pull Request

* Create a [pull request from your
  fork](https://docs.github.com/en/github/collaborating-with-issues-and-pull-requests/creating-a-pull-request-from-a-fork).
* Address PR feedback with fixup and/or squash commits:
```
git add .
git commit --fixup <commit SHA>
  -- or --
git commit --squash <commit SHA>
```
* Once approved, before merging into `main` squash your fixups with:
```
git fetch upstream
git rebase -i --autosquash upstream/main
git push --force-with-lease origin my_feature_branch
```

Your contribution will be analyzed for product fit and engineering
quality prior to merging. Your pull request is much more likely to be
accepted if it is small and focused with a clear message that conveys
the intent of your change.
