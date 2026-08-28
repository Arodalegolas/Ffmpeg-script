#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SRC="gdrive,root_folder_id=1hDOvcHyZjFpUIzeRfYl3pdjna8ikG0I_:"
DST="gdrive,root_folder_id=1iaVsGBe5Pnd41SGzPbNqh-e8suH77UMt:"
WORK_DIR="work"
MAX_SECONDS=19800    # ~5.5 horas de margen de seguridad
MIN_VALID_BYTES=5000000   # 5 MB: por debajo de esto, se considera archivo corrupto/incompleto

mkdir -p "$WORK_DIR"
start_time=$SECONDS

echo "Listando archivos de origen..."
rclone lsf --recursive --files-only "$SRC" | sort > all_files.txt

echo "Consultando estado real del destino (sin progress.log, sin fantasmas)..."
# name<TAB>size de cada archivo YA presente en destino
rclone lsjson --recursive "$DST" 2>/dev/null \
    | python3 -c "
import json, sys
for item in json.load(sys.stdin):
    if not item.get('IsDir'):
        print(f\"{item['Path']}\t{item['Size']}\")
" > dest_status.tsv 2>/dev/null || true

is_already_done() {
    local file="$1"
    local size
    size=$(awk -F'\t' -v f="$file" '$1==f{print $2}' dest_status.tsv)
    [ -n "$size" ] && [ "$size" -ge "$MIN_VALID_BYTES" ]
}

mapfile -t FILES < all_files.txt

for file in "${FILES[@]}"; do
    [ -z "$file" ] && continue

    if is_already_done "$file"; then
        echo "Ya existe en destino con tamaño válido, se omite: $file"
        continue
    fi

    elapsed=$((SECONDS - start_time))
    if [ "$elapsed" -ge "$MAX_SECONDS" ]; then
        echo "Se alcanzó el límite de tiempo. Vuelve a correr el workflow para continuar."
        break
    fi

    echo "=== Procesando: $file ==="
    in_path="$WORK_DIR/$file"
    out_path="$WORK_DIR/out_$file"

    mkdir -p "$(dirname "$in_path")" "$(dirname "$out_path")"

    if ! rclone copyto "${SRC}${file}" "$in_path" </dev/null; then
        echo "Falló la descarga de $file, se omite."
        rm -f "$in_path"
        continue
    fi

    # -nostdin: evita que ffmpeg intente leer de stdin y se coma el resto del bucle.
    # No forzar upscaling: si el ancho original es menor a 640, se mantiene.
    if ! ffmpeg -nostdin -y -i "$in_path" -vf "scale='min(640,iw)':'-2'" \
        -c:v libx264 -preset medium -b:v 301k -maxrate 301k -bufsize 602k \
        -c:a aac -b:a 48k -movflags +faststart "$out_path" </dev/null; then
        echo "Falló la conversión de $file, se omite."
        rm -f "$in_path" "$out_path"
        continue
    fi

    if ! rclone copyto "$out_path" "${DST}${file}" </dev/null; then
        echo "Falló la subida de $file, se reintentará en la próxima corrida."
        rm -f "$in_path" "$out_path"
        continue
    fi

    rm -f "$in_path" "$out_path"

    echo "Listo: $file"
done

echo "Corrida finalizada."
