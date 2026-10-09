#!/bin/bash
# Test script for rpimount: install tree if missing, then list a directory
# with permissions, owner and group. Defaults to /home when no argument is given.
# Usage: test-tree.sh [directory]

set -eu

dir="${1:-/home}"

if ! command -v tree >/dev/null 2>&1; then
    echo "tree not found, installing it..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y tree
fi

if [ ! -d "$dir" ]; then
    echo "error: '$dir' is not a directory" >&2
    exit 1
fi

# -p permissions, -u owner, -g group
tree -pug "$dir"
