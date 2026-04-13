# bash completion for git-arx
#
# Installation (pick one):
#   1. Per-user automatic: copy to ~/.local/share/bash-completion/completions/git-arx
#   2. Source manually:    add `source /path/to/git-arx-completion.bash` to ~/.bashrc
#
# The function name _git_arx is the convention git-completion.bash uses for
# external git commands: hyphens in the command name become underscores.

_git_arx_archived() {
    git arx list 2>/dev/null | awk 'NR > 2 { print $1 }'
}

_git_arx() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword

    if [[ $cword -eq 2 ]]; then
        __gitcomp "status update prune list ls log checkout add remove rm rename mv merge push fetch pull sync help"
        return
    fi

    local subcommand="${words[2]}"

    case "$subcommand" in
    status)
        __gitcomp "--sort=name --sort=date --order=asc --order=desc"
        ;;
    update)
        __gitcomp "--force --dry-run"
        ;;
    prune)
        __gitcomp "--force --dry-run"
        ;;
    list|ls)
        __gitcomp "--sort=name --sort=date --order=asc --order=desc --storage=file --storage=refs --author"
        ;;
    log)
        # First arg is the archived branch name; remaining args are git-log flags
        [[ $cword -eq 3 ]] && __gitcomp_nl "$(_git_arx_archived)"
        ;;
    checkout)
        [[ $cword -eq 3 ]] && __gitcomp_nl "$(_git_arx_archived)"
        ;;
    add)
        if [[ $cword -eq 3 ]]; then
            __gitcomp_nl "$(__git_heads)"
        elif [[ "$cur" == -* ]]; then
            __gitcomp "--force"
        fi
        ;;
    remove|rm)
        [[ $cword -eq 3 ]] && __gitcomp_nl "$(_git_arx_archived)"
        ;;
    rename|mv)
        # First arg: archived branch (old name); second arg: new name (free text)
        [[ $cword -eq 3 ]] && __gitcomp_nl "$(_git_arx_archived)"
        ;;
    merge)
        if [[ "$cur" == -* ]]; then
            __gitcomp "-o"
        else
            _filedir
        fi
        ;;
    push)
        if [[ "$prev" == "--delete" || "$prev" == "-d" ]]; then
            __gitcomp_nl "$(_git_arx_archived)"
        else
            __gitcomp "--force --dry-run --prune --delete"
        fi
        ;;
    fetch)
        ;;
    pull)
        ;;
    sync)
        __gitcomp "--dry-run --force-file --force-refs"
        ;;
    esac
}
