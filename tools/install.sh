#!/usr/bin/env bash
# Installs this checkout of the filter and records which commit it came from.
#
#   install.sh [-H HOST] [DIR]
#
# DIR defaults to /usr/local/lib/maddy-jev-filter, on HOST over ssh if -H is
# given. The new copy replaces the old one in one step, owned by root and
# readable by everyone so maddy can run it. Uncommitted changes are included,
# and VERSION then ends in "-dirty".
set -euo pipefail

host=''
while getopts H: opt; do
    case $opt in
    H) host=$OPTARG ;;
    *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
dir=${1:-/usr/local/lib/maddy-jev-filter}

cd "$(dirname "$0")/.."
version=$(git describe --always --dirty --abbrev=12)
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
git ls-files -z --cached --others --exclude-standard | tar --null -T - -czf "$archive"

script=$(cat <<EOF
set -euo pipefail
dir=$(printf '%q' "$dir") version=$(printf '%q' "$version") archive=\$1
tmp=\$(mktemp -d)
tar -xzf "\$archive" -C "\$tmp"
printf '%s\n' "\$version" > "\$tmp/VERSION"
sudo rm -rf "\$dir.new" "\$dir.old"
sudo mkdir -p "\$(dirname "\$dir")"
sudo cp -r "\$tmp" "\$dir.new"
rm -rf "\$tmp" "\$archive"
sudo chown -R root:root "\$dir.new"
sudo chmod -R u=rwX,go=rX "\$dir.new"
if [[ -e \$dir ]]; then sudo mv "\$dir" "\$dir.old"; fi
sudo mv "\$dir.new" "\$dir"
sudo rm -rf "\$dir.old"
EOF
)

if [[ -n $host ]]; then
    remote=/tmp/maddy-jev-filter-$$.tgz
    scp -q "$archive" "$host:$remote"
    ssh "$host" bash -s -- "$remote" <<< "$script"
else
    cp "$archive" "$archive.copy"
    bash -s -- "$archive.copy" <<< "$script"
fi
echo "installed $version to ${host:+$host:}$dir" >&2
