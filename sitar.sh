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

if ! $AWS --version > /dev/null 2>&1; then
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

    if s3exists 'SITAR-RESET.txt'; then
	NEW_LEVEL=$($AWS s3 cp -- "$S3BASE/SITAR-RESET.txt" -)
	if [ "$NEW_LEVEL" != $(echo "$NEW_LEVEL" | tr -dc '0-9') ] || [ "$NEW_LEVEL" -lt 0 ]; then
	    echo "$0: Invalid RESET value ignored: $NEW_LEVEL" 1>&2
	else
	    LAST_LEVEL="$NEW_LEVEL"
	fi
	$AWS s3 rm --only-show-errors -- "$S3BASE/SITAR-RESET.txt" || exit 1
    else
	LAST_LEVEL=$(cat "$TMPDIR/level.dat")
    fi

    if [ "$LAST_LEVEL" -ge "$MAX_LEVELS" ]; then
	LEVEL="$MAX_LEVELS"
    else
	LEVEL=$(($LAST_LEVEL + 1))
	cp "$TMPDIR/L$LAST_LEVEL.snar" "$TMPDIR/L$LEVEL.snar" || exit 1
    fi

    LAST=$(($(cat "$TMPDIR/last.dat") + 1))
    DEST="inc-$(printf '%05d-%03d' $LAST $LEVEL).$TAREXT"
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
    $AWS s3 --only-show-errors rm -- "$DEST"
    exit 1
fi

# Prune snar files for unused levels
L=$(($LEVEL + 1))
while [ -f "$TMPDIR/L$L.snar" ]; do
    rm -- "$TMPDIR/L$L.snar"
    L=$(($L + 1))
done

if [ -f "$TMPDIR/files.dat" ]; then
    # Prune files for unused levels.
    while read L name; do
	if [ "$L" -ge "$LEVEL" ]; then
	    $AWS s3 rm --only-show-errors -- "$S3BASE/$name" || exit 1
	else
	    echo "$L $name"
	fi
    done < "$TMPDIR/files.dat" > "$TMPDIR/files.dat.new"
    mv -- "$TMPDIR/files.dat.new" "$TMPDIR/files.dat"
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