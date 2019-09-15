#!/bin/sh
#
# Sitar - easy incremental backups to Amazon S3
#
# Copyright (c) 2018-2019 Flávio Veloso Soares
#
# This program is licences under the terms of the MIT license. See the
# file LICENSE for full licensing terms.
#

MAX_LEVELS=10

: ${AWS=aws}
: ${TAREXT="tar.bz2"}
: ${TAREXTRA="--bzip2"}

while getopts b:l: opt; do
    case "$opt" in
	n) MAX_LEVELS="$OPTARG";;
	*) exit 1
    esac
done
shift $(($OPTIND - 1))

DIR="$1"
S3BASE="$2"

if [ "$DIR" = "" -o "$S3BASE" = "" ]; then
    echo "$0: Invalid usage" 1>&2
    exit 1
fi

shift 2

if ! $AWS --version > /dev/null; then
    echo "$0: Could not get AWS CLI version" 1>&2
    exit 1
fi

# Ensure $S3BASE does end with a slash.
S3BASE=$(echo "$S3BASE" | sed 's,//*$,,')

s3exists() {
    local object="$1"
    $AWS s3 ls -- "$S3BASE/$object" > /dev/null
    return $?
}

s3catinto() {
    local object="$1"
    $AWS s3 cp -- - "$S3BASE/$object"
    return $?
}

FULL="full.$TAREXT"
METADATA=".sitar"

TMPDIR=$(mktemp -dt sitar.XXXXXX) || exit 1
trap "rm -rf $TMPDIR; exit 1" 1 2 3 4 5 6 7 8 10 11 12 13 14 15

mkdir -p "$TMPDIR"

if ! s3exists "$FULL"; then
    if [ $($AWS s3 ls -- "$S3BASE/" | wc -l) -gt 1 ]; then
	echo "$0: $S3BASE is not empty" 1>&2
	exit 1
    fi
    LEVEL=0
    LAST=0
    DEST="$FULL"
else
    $AWS s3 cp -- "$S3BASE/.sitar" - | tar xf - -C "$TMPDIR" || exit 1

    LAST_LEVEL=$(cat "$TMPDIR/level.dat")
    if [ "$LAST_LEVEL" -ge "$MAX_LEVELS" ]; then
	LEVEL="$MAX_LEVELS"
    else
	LEVEL=$(($LAST_LEVEL + 1))
	cp "$TMPDIR/L$LAST_LEVEL.snar" "$TMPDIR/L$LEVEL.snar" || exit 1
    fi

    LAST=$(($(cat "$TMPDIR/last.dat") + 1))
    DEST="inc-$(printf '%05d' $LAST).$TAREXT"
fi

# Create README.txt, if it does not exist.
if ! s3exists 'README.txt'; then
    cat <<EOF | s3catinto 'README.txt' || exit 1
These backup files were created by sitar.

To restore:

1. Untar the "full" tar ball first

2. Untar each "inc-*" tar ball in numeric sequence
EOF
fi

SNAR="$TMPDIR/L$LEVEL.snar"

if ! tar --create --listed-incremental="$SNAR" --file="-" \
     --exclude-ignore-recursive=.sitarignore \
     --exclude-tag=.sitarexclude \
     $TAREXTRA \
     --directory="$DIR" . "$@" | s3catinto "$DEST"; then
    $AWS s3 rm -- "$DEST"
    exit 1
fi

echo "$LAST" > "$TMPDIR/last.dat"
echo "$LEVEL" > "$TMPDIR/level.dat"
if [ "$LEVEL" -eq 0 ]; then
    rm -rf "$TMPDIR/files.dat"
else
    echo "$LEVEL $DEST" >> "$TMPDIR/files.dat"
fi
tar --create --file=- --directory="$TMPDIR" . | s3catinto "$METADATA"

rm -rf "$TMPDIR"

exit 0
