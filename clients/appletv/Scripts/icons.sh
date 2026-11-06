#!/bin/sh
# The app icon and Top Shelf image from the logo (Artwork/stream-logo.png):
# a layered icon — the logo in front, the app's background with a glow
# behind — so tvOS can give it parallax. Writes the brand assets into
# StreamTV/Assets.xcassets; run it again when the logo changes.
set -eu
cd "$(dirname "$0")/.."

LOGO=Artwork/stream-logo.png
OUT="StreamTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
BACKGROUND="#090B10" # Palette.background
GLOW="#1E6FD9"       # the logo's blue, softly behind it

command -v magick >/dev/null || { echo "icons.sh needs ImageMagick (brew install imagemagick)" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
magick "$LOGO" -trim +repage "$TMP/logo.png"

INFO='"info" : { "author" : "xcode", "version" : 1 }'

# back WIDTH HEIGHT FILE: the opaque background, a glow at its centre.
back() {
  glow=$(( $2 * 9 / 10 ))
  magick -size "${1}x${2}" "xc:$BACKGROUND" \
    \( -size "${glow}x${glow}" "radial-gradient:${GLOW}-black" \) \
    -gravity center -compose screen -composite -alpha off "$3"
}

# front WIDTH HEIGHT MARK FILE: the logo MARK pixels tall on transparency,
# nudged right — the play mark is heavier on its flat side, so the middle
# of its box isn't where it looks centred.
front() {
  nudge=$(( $3 / 30 ))
  magick -size "${1}x${2}" xc:none \
    \( "$TMP/logo.png" -resize "x$3" \) \
    -gravity center -geometry "+${nudge}+0" -compose over -composite "$4"
}

imageset() { # DIR then "scale:file" pairs
  set_dir=$1; shift
  mkdir -p "$set_dir"
  images=""
  for pair in "$@"; do
    images="$images${images:+,}{ \"idiom\" : \"tv\", \"scale\" : \"${pair%%:*}\", \"filename\" : \"${pair#*:}\" }"
  done
  printf '{ "images" : [ %s ], %s }\n' "$images" "$INFO" > "$set_dir/Contents.json"
}

# stack NAME W H SCALES...: an imagestack of a front and a back layer.
stack() {
  name=$1 w=$2 h=$3; shift 3
  dir="$OUT/$name.imagestack"
  for layer in Front Back; do
    pairs=""
    for scale in "$@"; do
      sw=$(( w * scale )) sh=$(( h * scale ))
      file="$layer@${scale}x.png"
      mkdir -p "$dir/$layer.imagestacklayer/Content.imageset"
      if [ "$layer" = Front ]; then
        front "$sw" "$sh" $(( sh * 62 / 100 )) "$dir/$layer.imagestacklayer/Content.imageset/$file"
      else
        back "$sw" "$sh" "$dir/$layer.imagestacklayer/Content.imageset/$file"
      fi
      pairs="$pairs ${scale}x:$file"
    done
    # shellcheck disable=SC2086
    imageset "$dir/$layer.imagestacklayer/Content.imageset" $pairs
    printf '{ %s }\n' "$INFO" > "$dir/$layer.imagestacklayer/Contents.json"
  done
  printf '{ "layers" : [ { "filename" : "Front.imagestacklayer" }, { "filename" : "Back.imagestacklayer" } ], %s }\n' \
    "$INFO" > "$dir/Contents.json"
}

# shelf NAME W H: a flat Top Shelf image, the logo on the background.
shelf() {
  name=$1 w=$2 h=$3
  dir="$OUT/$name.imageset"
  mkdir -p "$dir"
  for scale in 1 2; do
    sw=$(( w * scale )) sh=$(( h * scale ))
    back "$sw" "$sh" "$TMP/back.png"
    front "$sw" "$sh" $(( sh * 55 / 100 )) "$TMP/front.png"
    magick "$TMP/back.png" "$TMP/front.png" -compose over -composite -alpha off "$dir/TopShelf@${scale}x.png"
  done
  imageset "$dir" 1x:TopShelf@1x.png 2x:TopShelf@2x.png
}

rm -rf "$OUT"
mkdir -p "$OUT"
printf '{ %s }\n' "$INFO" > "StreamTV/Assets.xcassets/Contents.json"

stack "App Icon" 400 240 1 2
stack "App Icon - App Store" 1280 768 1
shelf "Top Shelf Image" 1920 720
shelf "Top Shelf Image Wide" 2320 720

cat > "$OUT/Contents.json" <<EOF
{
  "assets" : [
    { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
    { "filename" : "App Icon.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
    { "filename" : "Top Shelf Image Wide.imageset", "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" },
    { "filename" : "Top Shelf Image.imageset", "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" }
  ],
  $INFO
}
EOF
echo "wrote $OUT"
