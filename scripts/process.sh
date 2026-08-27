#!/usr/bin/env bash
set -uo pipefail

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
rclone lsf "$SRC" --files-only | sort > all_files.txt

while IFS= read -r file; do
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

    if ! rclone copyto "${SRC}${file}" "$in_path"; then
        echo "Falló la descarga de $file, se omite."
        rm -f "$in_path"
        continue
    fi

    if ! ffmpeg -y -i "$in_path" -vf "scale=640:-2" \
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
    git commit -m "Progreso: procesado $file" >/dev/null 2>&1
    git push >/dev/null 2>&1

    echo "Listo: $file"
done < all_files.txt

echo "Corrida finalizada."
