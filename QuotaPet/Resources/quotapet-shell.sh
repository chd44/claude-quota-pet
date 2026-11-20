# QuotaPet terminal integration: explicitly source this installed .app resource
# from interactive zsh/bash. No startup files are edited; no processes polled.
case $- in
    *i*) ;;
    *) return 0 ;;
esac

# Resolve this sourced file, not PATH, cwd, another installation, or an override.
# Keep the resolved target inside each wrapper so later variable changes cannot
# redirect it. printf %q safely quotes spaces, apostrophes and shell metacharacters.
if [ -n "${BASH_VERSION:-}" ]; then
    __quotapet_source=${BASH_SOURCE[0]}
elif [ -n "${ZSH_VERSION:-}" ]; then
    __quotapet_source=${(%):-%N}
else
    return 0
fi
__quotapet_resources=$(builtin cd -P -- "${__quotapet_source%/*}" 2>/dev/null && builtin pwd -P)
case "$__quotapet_resources/${__quotapet_source##*/}" in
    *.app/Contents/Resources/quotapet-shell.sh) ;;
    *)
        printf '%s\n' 'QuotaPet: source the quotapet-shell.sh inside an installed QuotaPet.app; integration skipped.' >&2
        unset __quotapet_source __quotapet_resources
        return 0 ;;
esac
__quotapet_contents=${__quotapet_resources%/Resources}
if [ ! -f "$__quotapet_contents/Info.plist" ] || [ ! -x "$__quotapet_contents/MacOS/QuotaPetLauncher" ]; then
    printf '%s\n' 'QuotaPet: this app has no usable QuotaPetLauncher; integration skipped.' >&2
    unset __quotapet_source __quotapet_resources __quotapet_contents
    return 0
fi
__quotapet_launcher_quoted=$(printf '%q' "$__quotapet_contents/MacOS/QuotaPetLauncher")

# Existing aliases/functions (including a previous source) are never replaced.
if alias codex >/dev/null 2>&1 || typeset -f codex >/dev/null 2>&1; then
    printf '%s\n' 'QuotaPet: kept existing codex alias/function; terminal integration skipped for codex.' >&2
else
    eval 'function codex {
        ( '"$__quotapet_launcher_quoted"' --wake-cli </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
        command codex "$@"
    }'
fi

if alias claude >/dev/null 2>&1 || typeset -f claude >/dev/null 2>&1; then
    printf '%s\n' 'QuotaPet: kept existing claude alias/function; terminal integration skipped for claude.' >&2
else
    eval 'function claude {
        ( '"$__quotapet_launcher_quoted"' --wake-cli </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
        command claude "$@"
    }'
fi
unset __quotapet_source __quotapet_resources __quotapet_contents __quotapet_launcher_quoted
