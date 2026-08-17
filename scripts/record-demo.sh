#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
run=/tmp/agent-workbench-vhs

usage() {
    cat <<'EOF'
Usage: scripts/record-demo.sh [overview|shell]

Environment:
  DEMO_NVIM_BIN Neovim wrapper (default: agent-workbench-demo-nvim)
  OUTPUT        GIF destination (scenario default: assets/demo.gif or assets/shell-worksheet.gif)
  SOURCE_VIDEO MP4 destination (default: /tmp/agent-workbench-vhs/<scenario>.mp4)
EOF
}

scenario=${1:-overview}
case "$scenario" in
overview) default_output=$repo/assets/demo.gif ;;
shell) default_output=$repo/assets/shell-worksheet.gif ;;
-h | --help)
    usage
    exit
    ;;
*)
    usage >&2
    exit 2
    ;;
esac

demo_nvim=${DEMO_NVIM_BIN:-agent-workbench-demo-nvim}
required=(ffmpeg "$demo_nvim" ttyd vhs)
[ "$scenario" != shell ] || required+=(btop fish)
for tool in "${required[@]}"; do
    command -v "$tool" >/dev/null || {
        echo "record-demo: required command not found: $tool" >&2
        exit 1
    }
done

output=${OUTPUT:-$default_output}
source_video=${SOURCE_VIDEO:-$run/$scenario.mp4}
generated_gif=$run/$scenario.gif
generated_video=$run/$scenario.mp4
mkdir -p "$run/bin" "$run/workspace/workspace-alpha" "$run/workspace/workspace-beta" \
    "$(dirname -- "$output")" "$(dirname -- "$source_video")"

cd "$repo"
unset VIMINIT EXINIT
export AGENT_WORKBENCH_REPO="$repo"
ln -sfn "$(command -v "$demo_nvim")" "$run/bin/nvim"
export PATH="$run/bin:$PATH"
vhs "scripts/demo/$scenario.tape"

for artifact in "$generated_gif" "$generated_video"; do
    [ -s "$artifact" ] || {
        echo "record-demo: VHS produced no artifact: $artifact" >&2
        exit 1
    }
done

atomic_copy() {
    local source=$1 destination=$2 temporary
    if [ "$source" = "$destination" ]; then
        return 0
    fi
    temporary=$destination.tmp.$$
    cp "$source" "$temporary"
    mv "$temporary" "$destination"
}

atomic_copy "$generated_gif" "$output"
atomic_copy "$generated_video" "$source_video"
echo "GIF: $output ($(du -h "$output" | cut -f1))"
echo "Source video: $source_video"
