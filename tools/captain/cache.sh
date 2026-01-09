CACHE_OK_FILE=".fetch_ok"

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo_time "Neither sha256sum nor shasum is available."
    return 1
  fi
}

read_kv() {
  # usage: read_kv <file> <key>
  local file="$1"
  local key="$2"
  # prints value, empty if not found
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,$2))}' "$file" 2>/dev/null | tail -n 1
}

cache_invalidate() {
  local dir="$1"
  rm -rf "$dir"
}

cache_mark_incomplete() {
  local dir="$1"
  rm -f "$dir/$CACHE_OK_FILE"
}

cache_mark_complete() {
  # args: dir fetch_sha
  local dir="$1"
  local fetch_sha="$2"
  {
    printf 'fetch_sh_sha256=%s\n' "$fetch_sha"
  } > "$dir/$CACHE_OK_FILE"
}

cache_is_complete_and_fresh() {
  # args: cache_dir fetch_sh_path
  local dir="$1"
  local fetch_sh="$2"

  [ -d "$dir" ] || return 1
  [ -f "$dir/$CACHE_OK_FILE" ] || return 1
  [ -f "$fetch_sh" ] || return 1

  local cur_sha
  cur_sha="$(sha256_file "$fetch_sh")" || return 1

  local saved_sha
  saved_sha="$(read_kv "$dir/$CACHE_OK_FILE" "fetch_sh_sha256")"

  [ -n "$saved_sha" ] || return 1
  [ "$saved_sha" = "$cur_sha" ] || return 2  # stale (fetch.sh changed)

  return 0
}

fetch_with_cache() {
  # args:
  #   $1: kind ("fuzzers" or "targets")
  #   $2: name
  #   $3: src_dir (template to rsync)
  #   $4: cache_dir
  #   $5: fetch_sh (path to fetch.sh)
  #   $6: export_var_name ("FUZZER" or "TARGET")
  local kind="$1"
  local name="$2"
  local src_dir="$3"
  local cache_dir="$4"
  local fetch_sh="$5"
  local export_var="$6"

  # Decide hit/miss

  cache_is_complete_and_fresh "$cache_dir" "$fetch_sh"
  cache_lookup_res=$?

  if [ "$cache_lookup_res" -eq 0 ]; then
    echo_time "Cache hit on $name"
  else
    if [ "$cache_lookup_res" -eq 2 ]; then
      echo_time "Cache stale on $name (fetch.sh changed). Re-fetching..."
      cache_invalidate "$cache_dir"
    elif [ -d "$cache_dir" ] && [ ! -f "$cache_dir/$CACHE_OK_FILE" ]; then
      echo_time "Incomplete cache for $name (missing $CACHE_OK_FILE). Re-fetching..."
      cache_invalidate "$cache_dir"
    else
      echo_time "Cache miss on $name, fetching..."
    fi
    mkdir -p "$(dirname "$cache_dir")"
  fi
  
  rsync -a --checksum "$src_dir" "$(dirname "$cache_dir")/"

  if [ "$cache_lookup_res" -eq 0 ]; then
    return 0
  fi

  cache_mark_incomplete "$cache_dir"

  # hash fetch.sh now (record what logic produced this cache)
  local fetch_sha
  fetch_sha="$(sha256_file "$fetch_sh")" || {
    echo_time "Failed to hash fetch.sh for $name"
    cache_invalidate "$cache_dir"
    return 1
  }

  export "${export_var}=$cache_dir"

  if ! "$fetch_sh" &> "${LOGDIR}/${name}_fetch.log"; then
    echo_time "Failed to fetch $name. Check fetch log for info."
    cache_invalidate "$cache_dir"
    return 1
  fi

  cache_mark_complete "$cache_dir" "$fetch_sha"
  return 0
}
