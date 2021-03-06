# `dhall-docs`

:construction: **This tool is on development phase yet. It is not usable right now.**

For installation or development instructions, see:

* [`dhall-haskell` - `README`](https://github.com/dhall-lang/dhall-haskell/blob/master/README.md)

## Introduction

This `dhall-docs` package provides a cli utility that takes a dhall package or
file and outputs a HTML documentation of it.

## Features

`dhall-docs` can analyze your Dhall package (essentially a folder with several
`.dhall` files) to generate documentation. Specifically:

* Extracts documentation from each file's header comments (see [Comment format](#comment-format)).
* The generated documentation includes breadcrumbs to aid navigation.
* Create an index for each folder in your package listing the `.dhall` files
  in that folder alongside the "exported packages" (the contained folders).
* Extracts examples from assertions.
* Extracts the type of each Dhall file from the source code and renders it
  in the indexes.
* Renders the original source code in each Dhall file's documentation.

To see a demo, visit the documentation for the [`Dhall Prelude`](https://hydra.dhall-lang.org/job/dhall-haskell/master/generate-dhall-docs/latest/download/1/docs).


## Comment format

The markup format for documentation is a strict Markdown flavor: [CommonMark].

Currently, there is no defined format for the documentation comments - we only
extract it from the "Header" of the files.

Also, the comment pre-processing is not done right now, so the best way to
write the documentation right now is starting from column 1.

For example. If you write the following:

```dhall
{-  foo
    bar
-}
```

... the markdown preprocessor will parse the second line as a indented codeblock,
which isn't what you'd expect from the tool.

At this moment, we recommend writing it this way:

```dhall
{-
foo
bar
-}
```

`dhall-docs` currently doesn't support multi-line line comments well: it just strips
the first `--`, not the other ones.

This will be improved soon and the standard documentation format will be published
alongside this package.

## Usage

The easiest usage is the following:

```bash
dhall-docs --input ${PACKAGE-FOLDER}
```

`dhall-docs` will store the documentation in
`${XDG_DATA_HOME}/dhall-docs/${OUTPUT-HASH}-${PACKAGE-NAME}/`, where:

* `$XDG_DATA_HOME` environment variable comes from the
    [xdg](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)
    specification. If it is not defined, `dhall-docs` will default to
    `~/.local/share/`.
* `OUTPUT-HASH` is the hash of the generated documentation. This is to make the
    folder [content-addressable](https://es.wikipedia.org/wiki/Content_Addressed_Storage).
    Also it avoids overwriting documentation folder when there was a change on
    the way it was generated.
* `PACKAGE-NAME` is the package name of your documentation. By default, it will
    be the basename of the `--input` folder, but you can override it via
    `--package-name`.

After generating the documentation, `dhall-docs` will create a symlink to the
documentation index at `./docs/index.html`. You can customize the location of
that symlink using `--output-link` flag, like this:

```bash
dhall-docs --input . --output-link ${OTHER_LINK}
```

For more information about the tool, check the `--help` flag.

## Development

### `ghci`

If you want to open the `ghci` repl on this package using `stack`, you have to
provide an additional flag:

```bash
stack ghci dhall-docs --flag dhall-docs:ghci-data-files
```

... otherwise the file-embedded css and fonts won't be properly linked

### Generated docs on Hydra

At this moment, the only package generated by `dhall-docs` on hydra jobsets is
the Dhall Prelude.

If you're in a PR, you can see it after a successful hydra build by visiting:

https://hydra.dhall-lang.org/job/dhall-haskell/${PR_NUMBER}/generate-dhall-docs/latest/download/1/docs

If you want to see the latest generated docs on master, visit:

https://hydra.dhall-lang.org/job/dhall-haskell/master/generate-dhall-docs/latest/download/1/docs

[CommonMark]: https://commonmark.org/
