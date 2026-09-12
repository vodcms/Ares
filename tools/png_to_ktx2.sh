#!/usr/bin/env bash
# png_to_ktx2.sh — Recursively convert PNG textures to KTX2 (UASTC) via toktx.
#
# Classifies textures by filename / path heuristics, then applies sRGB vs linear
# and quality/RDO presets so color maps keep color while data maps stay linear.
#
# Usage:
#   ./png_to_ktx2.sh <input_dir> [output_dir]
#
# Options (env vars):
#   DRY_RUN=1          Print actions only, do not convert
#   FORCE=1            Re-encode even if .ktx2 already exists
#   ZCMP=18            Zstd level (file size; little impact on decoded color)
#   SKIP_UNKNOWN=1     Skip files classified as unknown (default: treat as albedo)
#
# Examples:
#   ./png_to_ktx2.sh ./Textures
#   DRY_RUN=1 ./png_to_ktx2.sh ./Textures ./KTX2
#   FORCE=1 ./png_to_ktx2.sh ./Textures

set -euo pipefail

INPUT_DIR="${1:-}"
OUTPUT_DIR="${2:-}"

ZCMP="${ZCMP:-18}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
SKIP_UNKNOWN="${SKIP_UNKNOWN:-0}"

if [[ -z "$INPUT_DIR" ]]; then
  echo "Usage: $0 <input_dir> [output_dir]" >&2
  exit 1
fi

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "Error: input directory not found: $INPUT_DIR" >&2
  exit 1
fi

if ! command -v toktx >/dev/null 2>&1; then
  echo "Error: toktx not found in PATH (install KTX-Software)." >&2
  exit 1
fi

INPUT_DIR="$(cd "$INPUT_DIR" && pwd)"
if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
else
  OUTPUT_DIR="$INPUT_DIR"
fi

# --- classification ---------------------------------------------------------

# Returns: albedo | emissive | normal | data | unknown
classify_texture() {
  local path="$1"
  local lower base
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"

  # Directory hints (anywhere in path, including top-level folder)
  case "$lower" in
    */normal/*|*/normals/*|*/nrm/*|normal/*|normals/*|nrm/*) echo normal; return ;;
    */orm/*|*/masks/*|*/mask/*|*/roughness/*|*/metallic/*|*/ao/*|*/data/*|\
    orm/*|masks/*|mask/*|roughness/*|metallic/*|ao/*|data/*)
      echo data; return ;;
    */emissive/*|*/emission/*|emissive/*|emission/*) echo emissive; return ;;
    */albedo/*|*/diffuse/*|*/basecolor/*|*/base_color/*|*/color/*|*/ui/*|\
    albedo/*|diffuse/*|basecolor/*|base_color/*|color/*|ui/*)
      echo albedo; return ;;
  esac

  base="$(basename "$lower")"
  base="${base%.png}"

  # Tokenize on common separators so "foo_normal_2k" / "foo-n" / "foo.norm" match.
  local tokens
  tokens="_${base//[^a-z0-9]/_}_"

  # Normal (prefer long tokens; allow trailing _n)
  if [[ "$tokens" == *_normal_* || "$tokens" == *_norm_* \
     || "$tokens" == *_nrm_* || "$tokens" == *_nor_* ]]; then
    echo normal
    return
  fi
  if [[ "$base" =~ _n$ || "$base" =~ -n$ || "$base" =~ \.n$ ]]; then
    echo normal
    return
  fi

  # Packed / scalar data
  if [[ "$tokens" == *_orm_* || "$tokens" == *_mra_* || "$tokens" == *_arm_* \
     || "$tokens" == *_rma_* || "$tokens" == *_mask_* || "$tokens" == *_masks_* \
     || "$tokens" == *_rough_* || "$tokens" == *_roughness_* \
     || "$tokens" == *_metal_* || "$tokens" == *_metallic_* || "$tokens" == *_metalness_* \
     || "$tokens" == *_ao_* || "$tokens" == *_occlusion_* \
     || "$tokens" == *_height_* || "$tokens" == *_disp_* || "$tokens" == *_displacement_* \
     || "$tokens" == *_gloss_* || "$tokens" == *_specular_* || "$tokens" == *_spec_* \
     || "$tokens" == *_smoothness_* || "$tokens" == *_cavity_* ]]; then
    echo data
    return
  fi

  # Emissive
  if [[ "$tokens" == *_emis_* || "$tokens" == *_emissive_* \
     || "$tokens" == *_emission_* || "$tokens" == *_emit_* \
     || "$tokens" == *_glow_* ]]; then
    echo emissive
    return
  fi

  # Albedo / color (_a / _d / _bc common)
  if [[ "$tokens" == *_albedo_* || "$tokens" == *_alb_* \
     || "$tokens" == *_diff_* || "$tokens" == *_diffuse_* \
     || "$tokens" == *_basecolor_* || "$tokens" == *_base_color_* \
     || "$tokens" == *_basecol_* || "$tokens" == *_color_* \
     || "$tokens" == *_colour_* || "$tokens" == *_col_* \
     || "$tokens" == *_bc_* || "$base" =~ _a$ || "$base" =~ _d$ ]]; then
    echo albedo
    return
  fi

  echo unknown
}

# --- encode presets ---------------------------------------------------------

# Prints toktx args (newline-separated) for a class
toktx_args_for() {
  local kind="$1"
  case "$kind" in
    albedo)
      # Color: sRGB, moderate RDO
      printf '%s\n' \
        --t2 --encode uastc \
        --uastc_quality 2 --uastc_rdo_l 1.0 \
        --zcmp "$ZCMP" \
        --assign_oetf srgb \
        --genmipmap
      ;;
    emissive)
      # Keep color; lighter RDO than albedo
      printf '%s\n' \
        --t2 --encode uastc \
        --uastc_quality 2 --uastc_rdo_l 0.75 \
        --zcmp "$ZCMP" \
        --assign_oetf srgb \
        --genmipmap
      ;;
    normal)
      # Data: linear, higher quality, mild RDO
      printf '%s\n' \
        --t2 --encode uastc \
        --uastc_quality 3 --uastc_rdo_l 0.5 \
        --zcmp "$ZCMP" \
        --assign_oetf linear \
        --assign_primaries none \
        --genmipmap
      ;;
    data)
      # ORM/masks: linear, more aggressive size
      printf '%s\n' \
        --t2 --encode uastc \
        --uastc_quality 2 --uastc_rdo_l 1.5 \
        --zcmp "$ZCMP" \
        --assign_oetf linear \
        --assign_primaries none \
        --genmipmap
      ;;
    unknown)
      # Safe default: treat as color (sRGB)
      printf '%s\n' \
        --t2 --encode uastc \
        --uastc_quality 2 --uastc_rdo_l 1.0 \
        --zcmp "$ZCMP" \
        --assign_oetf srgb \
        --genmipmap
      ;;
  esac
}

# --- main -------------------------------------------------------------------

declare -A COUNTS=([albedo]=0 [emissive]=0 [normal]=0 [data]=0 [unknown]=0 [skip]=0 [fail]=0 [ok]=0)
UNKNOWN_LIST=()

mapfile -d '' PNGS < <(find "$INPUT_DIR" -type f \( -iname '*.png' \) -print0 | sort -z)

if [[ ${#PNGS[@]} -eq 0 ]]; then
  echo "No PNG files under: $INPUT_DIR"
  exit 0
fi

echo "Input:  $INPUT_DIR"
echo "Output: $OUTPUT_DIR"
echo "toktx:  $(command -v toktx)"
echo "Files:  ${#PNGS[@]}"
echo "--------"

for png in "${PNGS[@]}"; do
  [[ -z "$png" ]] && continue

  rel="${png#"$INPUT_DIR"/}"
  out="$OUTPUT_DIR/${rel%.*}.ktx2"
  out_dir="$(dirname "$out")"

  kind="$(classify_texture "$rel")"
  COUNTS["$kind"]=$(( COUNTS["$kind"] + 1 ))

  if [[ "$kind" == "unknown" ]]; then
    UNKNOWN_LIST+=("$rel")
    if [[ "$SKIP_UNKNOWN" == "1" ]]; then
      printf '[%-8s] SKIP  %s  (unknown)\n' "$kind" "$rel"
      COUNTS[skip]=$(( COUNTS[skip] + 1 ))
      continue
    fi
  fi

  if [[ -f "$out" && "$FORCE" != "1" ]]; then
    printf '[%-8s] SKIP  %s  (exists)\n' "$kind" "$rel"
    COUNTS[skip]=$(( COUNTS[skip] + 1 ))
    continue
  fi

  printf '[%-8s] CONV  %s\n' "$kind" "$rel"

  if [[ "$DRY_RUN" == "1" ]]; then
    continue
  fi

  mkdir -p "$out_dir"
  mapfile -t args < <(toktx_args_for "$kind")

  if toktx "${args[@]}" "$out" "$png"; then
    COUNTS[ok]=$(( COUNTS[ok] + 1 ))
  else
    echo "  ! failed: $rel" >&2
    COUNTS[fail]=$(( COUNTS[fail] + 1 ))
    rm -f "$out"
  fi
done

echo "--------"
echo "Classification:"
printf '  albedo:    %d\n' "${COUNTS[albedo]}"
printf '  emissive:  %d\n' "${COUNTS[emissive]}"
printf '  normal:    %d\n' "${COUNTS[normal]}"
printf '  data:      %d\n' "${COUNTS[data]}"
printf '  unknown:   %d\n' "${COUNTS[unknown]}"
echo "Results:"
printf '  converted: %d\n' "${COUNTS[ok]}"
printf '  skipped:   %d\n' "${COUNTS[skip]}"
printf '  failed:    %d\n' "${COUNTS[fail]}"

if [[ ${#UNKNOWN_LIST[@]} -gt 0 ]]; then
  echo "--------"
  echo "Unknown files (defaulted to sRGB albedo; use SKIP_UNKNOWN=1 to skip):"
  for u in "${UNKNOWN_LIST[@]}"; do
    echo "  - $u"
  done
  echo "Tip: rename with _albedo / _normal / _orm, or put under Albedo|Normal|ORM folders."
fi

if [[ "${COUNTS[fail]}" -gt 0 ]]; then
  exit 1
fi
