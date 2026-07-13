#!/bin/bash
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

if [ -z "$(git status --porcelain)" ]; then
  exit 0
fi

changed_files=$(git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
file_count=$(echo "$changed_files" | grep -c .)

timestamp=$(date "+%m-%d %H:%M")
summary=$(echo "$changed_files" | head -3 | tr '\n' ', ' | sed 's/,$//')

if [ "$file_count" -gt 3 ]; then
  summary="$summary 等 ${file_count} 个文件"
fi

git add -A
git commit -m "auto: ${timestamp} ${summary}"
