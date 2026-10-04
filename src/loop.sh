# petal's loop for Git Bash. petal starts bash with -c 'eval "$PETAL_LOOP"', its standard input the
# request pipe, its standard output the answer pipe. A request is one line "<op> <id> <text>", the
# text with every byte outside printable ASCII, and every backslash, written as \xHH. Every answer
# starts with a line "<op> <id> <length>..." followed by fields of exactly those many bytes.
# After each command, "\0petal-stray <id>" goes to standard error, the shell's own output, before
# the answer: what a program wrote there before it was written during or before that command.
unset PETAL_LOOP
chcp.com 65001 >/dev/null 2>&1
if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
    __petal_funsub=1
else
    __petal_funsub=0
fi
__petal_last_env=

__petal_bytes() {
    local LC_ALL=C
    __petal_n=${#1}
}

__petal_bytes "$BASH_VERSION"
builtin printf 'ready 0 %s\n%s' "$__petal_n" "$BASH_VERSION"

# Bash 5.3 captures a builtin's output without starting a subshell; older versions fork one.
__petal_snapshot() {
    if (( __petal_funsub )); then
        builtin eval '__petal_env=${ builtin export -p; }; __petal_win=${ builtin pwd -W 2>/dev/null; }'
    else
        __petal_env=$(builtin export -p)
        __petal_win=$(builtin pwd -W 2>/dev/null)
    fi
}

while IFS= builtin read -r __petal_line; do
    __petal_op=${__petal_line%% *}
    __petal_rest=${__petal_line#* }
    __petal_id=${__petal_rest%% *}
    __petal_arg=${__petal_rest#* }
    builtin printf -v __petal_request '%b' "$__petal_arg"
    case $__petal_op in
        run)
            __petal_out=${__petal_request%%$'\n'*}
            __petal_command=${__petal_request#*$'\n'}
            for __petal_once in 1; do builtin eval "$__petal_command"; done </dev/null >"$__petal_out" 2>&1
            __petal_status=$?
            __petal_snapshot
            if [[ $__petal_env == "$__petal_last_env" ]]; then
                __petal_envout=
            else
                __petal_last_env=$__petal_env
                __petal_envout=$__petal_env
            fi
            __petal_bytes "$__petal_win"; __petal_a=$__petal_n
            __petal_bytes "$PWD"; __petal_b=$__petal_n
            __petal_bytes "$__petal_envout"; __petal_c=$__petal_n
            builtin printf '\0petal-stray %s\n' "$__petal_id" >&2
            builtin printf 'done %s %s %s %s %s\n%s%s%s' "$__petal_id" "$__petal_status" "$__petal_a" "$__petal_b" "$__petal_c" "$__petal_win" "$PWD" "$__petal_envout"
            ;;
        resolve)
            __petal_names=($__petal_request)
            builtin printf 'resolved %s %s\n' "$__petal_id" "${#__petal_names[@]}"
            for __petal_name in "${__petal_names[@]}"; do
                if [[ $__petal_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [[ -v $__petal_name ]]; then
                    __petal_value=${!__petal_name}
                    __petal_bytes "$__petal_value"
                    builtin printf '%s\n%s' "$__petal_n" "$__petal_value"
                else
                    builtin printf -- '-1\n'
                fi
            done
            ;;
        restore)
            builtin eval "$__petal_request" >/dev/null 2>&1
            builtin printf 'restored %s\n' "$__petal_id"
            ;;
        *)
            builtin printf 'unknown %s\n' "$__petal_id"
            ;;
    esac
done
builtin exit 0
