#!/bin/zsh
# Package the workflow: zsh build.zsh <version> <output.alfredworkflow>
# A .alfredworkflow is a zip of the workflow folder. The version is stamped
# into the packaged copy only, so the source keeps "dev".
emulate -L zsh
setopt err_return

SRC=${0:A:h}
FILES=(info.plist icon.png lib.zsh filter.zsh action.zsh askpass.zsh)

function build_workflow() {
    local version=${1:-} out=${2:-} src=$SRC stage file
    if [ -z "$version" ] || [ -z "$out" ]; then
        print -u2 "Usage: build.zsh <version> <output.alfredworkflow>"
        return 1
    fi
    for file in $FILES; do
        if [ ! -f "$src/$file" ]; then
            print -u2 "Missing $src/$file"
            return 1
        fi
    done
    stage=$(mktemp -d)
    cp -p "${FILES[@]/#/$src/}" "$stage/"
    plutil -replace version -string "$version" "$stage/info.plist"
    out=${out:A}
    rm -f "$out"
    (cd "$stage" && zip -q -X "$out" $FILES)
    rm -rf "$stage"
    print -r -- "$out"
}

build_workflow "$@"
