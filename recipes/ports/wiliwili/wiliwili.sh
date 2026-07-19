#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$dir/libs:$dir/libs.aarch64:$LD_LIBRARY_PATH"
cd "$dir"
exec ./"wiliwili" "$@"
