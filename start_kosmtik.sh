#! /usr/bin/env bash

set -euo pipefail

KOSMTIK_VERSION=${KOSMTIK_VERSION:-b9ff1df74aa259cf5557e67e859c53ce7e8a87d3}

function print_help {
    echo "Usage: $0 [OPTIONS] DIRECTORY MML_FILE"
    echo ""
    echo "Options:"
    echo "  -p=ARG, --port=ARG         Port where Kosmtik should listen at (default 6789)"
    echo "  -d=ARG, --dir=ARG          Directory to mount at /mapstyle where all resources"
    echo "                             required by the map style. (required)"
    echo "  -m=ARG, --mml=ARG          Path to the .mml file relative to the path provided"
    echo "                             by --dir. (required)"
    echo "  -M=ARG1:ARG2, --extra-mount=ARG1:ARG2"
    echo "                             Mount directory ARG1 on host to ARG2 in the container"
    echo "  -f=ARG, --add-font-dir=ARG Additional search paths for fonts. They will be added"
    echo "                             to the system paths."
    echo "  -F=ARG, --fontconfig=ARG   Path to fontconfig configuration (defaults to"
    echo "                             /etc/fonts/fonts.conf)"
    echo "  -n, --no-fontconfig        Do not read fontconfig configuration. Use this option"
    echo "                             on hosts where fontconfig is not installed. It is"
    echo "                             recommended to provide the font directories using -f."
    echo "  -P=ARG, --pg-port=ARG      Specify PostgreSQL TCP port manually. Use this option if"
    echo "                             pg_conftool is not available on the host. You need this"
    echo "                             although PostgreSQL is accessed via its Unix socket because"
    echo "                             its Unix socket is named after the TCP port."
    echo "  -s=ARG, --socket-dir=ARG   Specify socket directory manually. Use this option if"
    echo "                             pg_conftool is not available on the host."
    exit 1
}


OPTS=`getopt -o p:d:m:M:f:F:nP:s:h --long port:dir:mml:add-font-dir:fontconfig:no-fontconfig:pg-port:socket-dir,help -n 'parse-options' -- "$@"`

if [ $? != 0 ] ; then
    echo "Failed parsing options." >&2
    print_help
fi

PORT=6789
DIRECTORY=""
MML_FILE=""
FONTCONFIG="/etc/fonts/fonts.conf"
DISABLE_FONTCONFIG=0
EXTRA_MOUNT=""
PG_PORT=""
PG_SOCKET_DIR=""
declare -a FONT_DIRS

eval set -- "$OPTS"

while true; do
    case "$1" in
        -p | --port ) PORTMAPPING=$2; shift; shift ;;
        -d | --dir ) DIRECTORY=$2; shift; shift ;;
        -m | --mml ) MML_FILE=$2; shift; shift ;;
        -f | --add-font-dir ) FONT_DIRS+=($2); shift; shift ;;
        -F | --fontconfig ) FONTCONFIG=$2; shift; shift ;;
        -n | --no-fontconfig ) DISABLE_FONTCONFIG=1; shift ;;
        -M | --extra-mount ) EXTRA_MOUNT=$2; shift; shift ;;
        -P | --pg-port ) PG_PORT=$2; shift; shift ;;
        -s | --socket-dir ) PG_SOCKET_DIR=$2; shift; shift ;;
        -h | --help )    print_help; exit ;;
        -- ) shift; break ;;
        * ) break ;;
    esac
done

if [ "$DIRECTORY" == "" ] || [ "$MML_FILE" == "" ] ; then
    echo "ERROR: Missing options --dir and/or --mml."
    print_help
fi

if [ "$DISABLE_FONTCONFIG" -eq 0 ] ; then
    echo "Detecting system font directories"
    FONT_DIR_COUNT=$(xmllint --xpath 'count(fontconfig/dir)' ${FONTCONFIG})
    for IDX in `seq 1 $FONT_DIR_COUNT`; do
        FONT_PATH=$(xmllint --xpath "fontconfig/dir[$IDX]/text()" ${FONTCONFIG})
        echo "Adding $FONT_PATH to font search path"
        FONT_DIRS+=($FONT_PATH)
    done
fi

echo "Creating temporary directory where all font directories are linked from"
TEMP_FONT_DIR=$(mktemp -d)
TEMP_INDEX=1
for DIR in ${FONT_DIRS[@]} ; do
    if [ -d "$DIR" ] ; then
        echo "Copying all files in $DIR from $TEMP_FONT_DIR/$TEMP_INDEX"
        cp -r "$DIR" "$TEMP_FONT_DIR/$TEMP_INDEX"
    else
        echo "WARNING: Font directory $DIR does not exist"
    fi
    TEMP_INDEX=$((TEMP_INDEX + 1))
done

# Get path to PostgreSQL socket
# See also https://www.jujens.eu/posts/en/2017/Feb/15/docker-unix-socket/
if [ "$PG_SOCKET_DIR" = "" ] ; then
    PG_SOCKET_DIR=$(pg_conftool show unix_socket_directories | sed -Ee "s/unix_socket_directories = '([^']+)'$/\1/g")
fi
if [ "$PG_PORT" = "" ] ; then
    PG_PORT=$(pg_conftool show port | sed -Ee "s/port = '([^']+)'$/\1/g")
fi
PG_SOCKET_FILENAME="/.s.PGSQL.$PG_PORT"
PG_SOCKET_PATH="$PG_SOCKET_DIR/$PG_SOCKET_FILENAME"

# Check if MML_FILE points is resolvable as path relative to DIRECTORY and points to a file or symlink.
# First, check if MML_FILE starts with a slash to denote an absolute path which would be wrong.
if [ $(echo "$MML_FILE" | sed -Ee "s,^/.*$,/,g") == "/" ] ; then
    echo "ERROR: $MML_FILE starts with a slash. The path should be relative to $DIRECTORY and should be a relative path!"
    exit 1
fi
# Ensure that MML_FILE does not contain .. to avoid directory traversal issues.
TEST_RESULT=$(echo "$MML_FILE" | grep -Eoe "(^|/)\.\.($|/)") || true
if [ "$TEST_RESULT" != "" ] ; then
    echo "ERROR: Illegal directory traversal in $MML_FILE detected."
    exit 1
fi
MML_PATH_FULL=$DIRECTORY/$MML_FILE
if [ ! -f "$MML_PATH_FULL" ] && [ ! -L "$MML_PATH_FULL" ] ; then
    echo "ERROR: $MML_FILE is not resolveable as path relative to $DIRECTORY"
    exit 1
fi

SCRIPTDIR=$(dirname $0)

MOUNT_ARG=""
if [ "$EXTRA_MOUNT" != "" ] ; then
    MOUNT_ARG="--mount=type=bind,source=$(echo $EXTRA_MOUNT | cut -d : -f 1),destination=$(echo $EXTRA_MOUNT | cut -d : -f 2)"
    echo $MOUNT_ARG
fi

echo "Starting container"
docker run \
    --attach=STDIN --attach=STDOUT --attach=STDERR \
    --interactive=true --tty=true \
    --network=host \
    --expose=$PORT \
    --user=$(id -u ${USER}):$(id -g ${USER}) \
    --mount=type=bind,source=$PG_SOCKET_DIR,destination=/var/run/postgresql,ro=true \
    --mount=type=bind,source=$DIRECTORY,destination=/mapstyle,ro=true \
    --mount=type=bind,source=$TEMP_FONT_DIR,destination=/additional-fonts,ro=true \
    $MOUNT_ARG \
    --env="MML_FILE=$MML_FILE" \
    --env="PORT=$PORT" \
    kosmtik:$KOSMTIK_VERSION || true

CONTAINER_ID=$(docker container ls -a -q -f ancestor=kosmtik:$KOSMTIK_VERSION)

echo "Removing all Kosmtik containers: $CONTAINER_ID"
docker container rm $CONTAINER_ID

echo "Removing temporary directory $TEMP_FONT_DIR"
rm -r $TEMP_FONT_DIR
