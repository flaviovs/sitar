#!/bin/sh
#
# Sitar - easy incremental backups to Amazon S3
#
# Copyright (c) 2018-2019 Flávio Veloso Soares
#
# This program is licenced under the terms of the MIT license. See the
# file LICENSE for full licensing terms.
#

: ${AWS=aws}

COMPRESS=
while getopts C: opt; do
    case "$opt" in
	    C) COMPRESS="$OPTARG";;
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

if ! command -v gzip > /dev/null; then
    echo "$0: gzip is a requirement" 1>&2
    exit 1
fi

# Figure out compression method and parameters
if [ "$COMPRESS" = "" ]; then
    if command -v bzip2 > /dev/null; then
	    COMPRESS=bzip2
    else
	    COMPRESS=gzip
    fi
fi

case "$COMPRESS" in
    bzip2)
	    TAREXT="tar.bz2"
	    TARCOMPRESS="--bzip2"
	    ;;

    gzip)
	    TAREXT="tar.gz"
	    TARCOMPRESS="--gzip"
	    ;;

    xz)
        TAREXT="tar.xz"
        TARCOMPRESS="--xz"
        ;;

    none)
        TAREXT="tar"
        TARCOMPRESS=""
        ;;

    *)
        echo "$0: Invalid compression method: $COMPRESS" 1>&2
        exit 1
esac

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

TMPDIR=$(mktemp -dt sitar.XXXXXX) || exit 1
trap "rm -rf $TMPDIR; exit 1" 1 2 3 4 5 6 7 8 10 11 12 13 14 15

mkdir -p "$TMPDIR/sitar"

if ! s3exists ".sitar"; then
    if [ $($AWS s3 ls -- "$S3BASE/" | wc -l) -gt 1 ]; then
        echo "$0: $S3BASE is not empty" 1>&2
        exit 1
    fi
    LEVEL=0
    LAST=0
    DEST="full.$TAREXT"
else
    $AWS s3 cp -- "$S3BASE/.sitar" - | \
        tar --gzip --extract --file=- --directory="$TMPDIR/sitar" || exit 1

    FULL_FILE=$(awk '$1 == 0 { print $2 }' "$TMPDIR/sitar/files.dat") || exit 1
    if ! s3exists "$FULL_FILE"; then
        echo "$0: Full backup missing: $S3BASE/$FULL_FILE" 1>&2
        exit 1
    fi

    LAST_LEVEL=$(cat "$TMPDIR/sitar/level.dat")
    if s3exists 'SITAR-RESET.txt'; then
        NEW_LEVEL=$($AWS s3 cp -- "$S3BASE/SITAR-RESET.txt" -)
        if [ "$NEW_LEVEL" != $(echo "$NEW_LEVEL" | tr -dc '0-9') ] || [ "$NEW_LEVEL" -lt 0 ]; then
            echo "$0: Invalid RESET value ignored: $NEW_LEVEL" 1>&2
        elif [ "$NEW_LEVEL" -lt "$LAST_LEVEL" ]; then
            LAST_LEVEL="$NEW_LEVEL"
        fi
        $AWS s3 rm --only-show-errors -- "$S3BASE/SITAR-RESET.txt" || exit 1
    fi

    LEVEL=$(($LAST_LEVEL + 1))
    cp "$TMPDIR/sitar/L$LAST_LEVEL.snar" "$TMPDIR/sitar/L$LEVEL.snar" || exit 1

    LAST=$(($(cat "$TMPDIR/sitar/last.dat") + 1))
    DEST="inc-$(printf '%05d-%03d' $LAST $LEVEL).$TAREXT"
fi

# Create README.txt, if it does not exist.
if ! s3exists 'README.txt'; then
    cat <<EOF | s3catinto 'README.txt' || exit 1
These backup files were created by sitar. See
https://github.com/flaviovs/sitar for more details.

To restore:

1. Download "full.tar.bz2" and all "inc-*.tar.bz2" files.

2. Create a directory to hold restored files:

   mkdir /tmp/restore

3. Untar the full backup:

   tar xf full.tar.bz2 --bzip2 --listed-incremental=/dev/null -C /tmp/restore

4. Restore all incremental backups in numerical order:

   LC_ALL=C ls inc-*.tar.bz2 | while read file; do \\
     tar xf "\$file" --bzip2 --listed-incremental=/dev/null -C /tmp/restore; done

Note: these instructions assume your backups were all done using
bzip2(1). Adjust command lines and file names if not.
EOF
fi

SNAR="$TMPDIR/sitar/L$LEVEL.snar"

(
    tar --create --listed-incremental="$SNAR" --file="-" \
        --exclude-ignore=.sitarignore \
        --exclude-tag=.sitarskip \
        $TARCOMPRESS "$@" \
        --directory="$DIR" .;
    echo "$?" > "$TMPDIR/tarrc.txt"
) | $AWS s3 cp $AWSCLI_EXTRA - "$S3BASE/$DEST"
S3RC=$?
TARRC=$(cat $TMPDIR/tarrc.txt)
if [ $S3RC -ne 0 -o $TARRC -ne 0 ]; then
    $AWS s3 --only-show-errors rm -- "$S3BASE/$DEST"
    exit 1
fi

# Prune snar files for unused levels
L=$(($LEVEL + 1))
while [ -f "$TMPDIR/sitar/L$L.snar" ]; do
    rm -- "$TMPDIR/sitar/L$L.snar"
    L=$(($L + 1))
done

if [ -f "$TMPDIR/sitar/files.dat" ]; then
    # Prune files for unused levels.
    while read L name; do
	if [ "$L" -ge "$LEVEL" ]; then
	    $AWS s3 rm --only-show-errors -- "$S3BASE/$name" || exit 1
	else
	    echo "$L $name"
	fi
    done < "$TMPDIR/sitar/files.dat" > "$TMPDIR/files.dat.new"
    mv -- "$TMPDIR/files.dat.new" "$TMPDIR/sitar/files.dat"
fi

echo "$LAST" > "$TMPDIR/sitar/last.dat"
echo "$LEVEL" > "$TMPDIR/sitar/level.dat"
echo "$LEVEL $DEST" >> "$TMPDIR/sitar/files.dat"

tar --gzip --create --file=- --directory="$TMPDIR/sitar" . | s3catinto ".sitar"

rm -rf "$TMPDIR"

exit 0
