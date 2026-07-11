#!/usr/bin/env bash
# Import an LM Studio GGUF into ollama WITHOUT duplicating the weights on disk.
# `ollama create` copies the GGUF into the blob store (content-addressed), so afterwards we swap
# the referenced model blob for a symlink back to the original GGUF and prune orphan blobs.
# LM Studio stays the download/browse UI; ollama serves. Deleting a model in LM Studio breaks the
# symlink loudly (load error) — re-download or `ollama rm` then.
#
# Usage: OLLAMA_HOST=... ./local/ollama-import.sh <gguf-path> <model-name> [num_ctx]
#   num_ctx is the serving context pin (ollama loads at exactly this; no JIT-shrink trap).
#   Pin the LARGEST ctx any role/class needs for the model (see local/llm.sh role map).
set -euo pipefail

GGUF="$(readlink -f "${1:?gguf path}")"
NAME="${2:?model name}"
CTX="${3:-}"
STORE="${OLLAMA_MODELS:-$HOME/.cache/ollama-user}"

[ -f "$GGUF" ] || { echo "no such gguf: $GGUF" >&2; exit 1; }

MF="$(mktemp)"
trap 'rm -f "$MF"' EXIT
{ echo "FROM $GGUF"; [ -n "$CTX" ] && echo "PARAMETER num_ctx $CTX"; } > "$MF"
ollama create "$NAME" -f "$MF"

REF="$NAME"; TAG="latest"
case "$REF" in *:*) TAG="${REF##*:}"; REF="${REF%%:*}" ;; esac
case "$REF" in
  */*) MANIFEST="$STORE/manifests/registry.ollama.ai/$REF/$TAG" ;;
  *)   MANIFEST="$STORE/manifests/registry.ollama.ai/library/$REF/$TAG" ;;
esac
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST (store mismatch? OLLAMA_MODELS)" >&2; exit 1; }

DIGEST="$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.model") | .digest' \
  "$MANIFEST" | tr ':' '-')"
BLOB="$STORE/blobs/$DIGEST"
if [ ! -L "$BLOB" ]; then
  rm "$BLOB"
  ln -s "$GGUF" "$BLOB"
fi
echo "linked: $BLOB -> $GGUF"

# prune orphan file blobs (create leaves a raw-sha copy of the GGUF behind)
REFS="$(find "$STORE/manifests" -type f -exec cat {} + 2>/dev/null \
  | jq -r '.config.digest, .layers[].digest' | tr ':' '-' | sort -u)"
for b in "$STORE"/blobs/sha256-*; do
  [ -L "$b" ] && continue
  base="$(basename "$b")"
  grep -qx "$base" <<<"$REFS" || { rm "$b"; echo "pruned orphan: $base"; }
done

ollama show "$NAME" >/dev/null && echo "imported: $NAME (num_ctx ${CTX:-default})"
