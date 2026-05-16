#!/usr/bin/env bash
# Compose a self-contained HelmRelease v2 schema for the bjw-s app-template chart.
#
# Reads every JSON schema from `charts/library/common/{values,schemas/*}` under
# the vendor dir, parks each one under `$defs/<safe-name>` of our Flux
# HelmRelease v2 schema, and rewrites every $ref (intra-document, relative,
# absolute) to an intra-document JSON Pointer. The result has no remote refs,
# so editors that don't follow cross-document refs still get full completion
# under .spec.values.
#
# Usage: compose.sh <vendor-dir> <output-dir> <site-dir>
set -euo pipefail

VENDOR="${1:?usage: compose.sh <vendor-dir> <output-dir> <site-dir>}"
OUTPUT="${2:?usage: compose.sh <vendor-dir> <output-dir> <site-dir>}"
SITE="${3:?usage: compose.sh <vendor-dir> <output-dir> <site-dir>}"

common_dir="$VENDOR/charts/library/common"
flux_hr="$SITE/helm.toolkit.fluxcd.io/helmrelease_v2.json"

defs_tmp=$(mktemp)
trap 'rm -f "$defs_tmp"' EXIT

jq -s '
  def safe_name:
    sub(".*?/charts/library/common/"; "")
    | sub("\\.schema\\.json$"; "")
    | sub("\\.json$"; "")
    | gsub("/"; "_")
  ;

  def rewrite_ref($current; $names):
    (.["$ref"]) as $ref
    | (if ($ref | contains("#")) then ($ref | split("#")) else [$ref, ""] end) as $parts
    | $parts[0] as $url
    | $parts[1] as $frag
    | (if $frag != "" then "/" + ($frag | sub("^/"; "")) else "" end) as $fragpath
    | if $url == "" then
        .["$ref"] = "#/$defs/" + $names[$current] + $fragpath
      elif ($url | startswith("http")) and ($names | has($url)) then
        .["$ref"] = "#/$defs/" + $names[$url] + $fragpath
      else
        (($current | sub("/[^/]+$"; "/")) + $url) as $abs
        | if $names | has($abs) then
            .["$ref"] = "#/$defs/" + $names[$abs] + $fragpath
          else . end
      end
  ;

  (map({key: .["$id"], value: (.["$id"] | safe_name)}) | from_entries) as $names
  | map({
      key: (.["$id"] | safe_name),
      value: (
        .["$id"] as $cur
        | walk(if type == "object" and ((.["$ref"]? // null) | type) == "string"
               then rewrite_ref($cur; $names) else . end)
        | del(.["$id"], .["$schema"])
      )
    })
  | from_entries
' "$common_dir/values.schema.json" "$common_dir/schemas"/*.json > "$defs_tmp"

mkdir -p "$OUTPUT"
jq --slurpfile defs "$defs_tmp" '
  .["$defs"] = $defs[0]
  | .properties.spec.properties.values = {
      "description": "Values holds the values for this Helm release, constrained to the bjw-s app-template common library schema.",
      "$ref": "#/$defs/values"
    }
' "$flux_hr" > "$OUTPUT/helmrelease-helm-v2.schema.json"

echo "composed $OUTPUT/helmrelease-helm-v2.schema.json" >&2
