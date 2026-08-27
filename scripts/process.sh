#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SRC="gdrive,root_folder_id=1hDOvcHyZjFpUIzeRfYl3pdjna8ikG0I_:"
DST="gdrive,root_folder_id=1iaVsGBe5Pnd41SGzPbNqh-e8suH77UMt:"
PROGRESS_FILE="progress.log"
WORK_DIR="work"
MAX_SECONDS=19800   # ~5.5 horas de margen de seguridad

mkdir -p "$WORK_DIR"
touch "$PROGRESS_FILE"

start_time=$SECONDS

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

echo "Listando archivos de origen..."
# Listar recursivamente, solo archivos, mantener rutas relativas
rclone lsf --recursive --files-only "$SRC" | sort > all_files.txt

while IFS= read -r file || [ -n "${file:-}" ]; do
    # Ignorar líneas vacías
    [ -z "$file" ] && continue

    if grep -Fxq "$file" "$PROGRESS_FILE"; then
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

    if ! rclone copyto "${SRC}${file}" "$in_path"; then
        echo "Falló la descarga de $file, se omite."
        rm -f "$in_path"
        continue
    fi

    # No forzar upscaling: si el ancho es menor, se mantiene
    if ! ffmpeg -y -i "$in_path" -vf "scale='min(640,iw)':'-2'" \
        -c:v libx264 -preset medium -b:v 301k -maxrate 301k -bufsize 602k \
        -c:a aac -b:a 48k -movflags +faststart "$out_path"; then
        echo "Falló la conversión de $file, se omite."
        rm -f "$in_path" "$out_path"
        continue
    fi

    if ! rclone copyto "$out_path" "${DST}${file}"; then
        echo "Falló la subida de $file, se reintentará en la próxima corrida."
        rm -f "$in_path" "$out_path"
        continue
    fi

    rm -f "$in_path" "$out_path"

    echo "$file" >> "$PROGRESS_FILE"
    git add "$PROGRESS_FILE"
    git commit -m "fix: corregir process.sh — rclone/ffmpeg y robustez" || echo "⚠️ Falló el commit de $file"
    git push || echo "⚠️ Falló el push de $file"

    echo "Listo: $file"
done < all_files.txt

echo "Corrida finalizada."
