# bash completion for clipbender
# Install: source this file, or drop it in /usr/share/bash-completion/completions/clipbender

_clipbender() {
    local cur prev words cword
    _init_completion || return

    local subcommands="set get clear shutdown"
    # Register keywords usable as set destinations/sources.
    local keywords="clipboard primary"

    # First word after `clipbender` is the subcommand.
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
        return
    fi

    local subcmd="${words[1]}"
    case "$subcmd" in
    set)
        # set <destination> [source]
        # destination (cword 2): a-z, A-Z, clipboard, primary
        # source      (cword 3): 0-9, a-z, @0-@9, clipboard, primary
        COMPREPLY=($(compgen -W "$keywords" -- "$cur"))
        ;;
    clear)
        # clear <named register a-z> — no keyword completions
        COMPREPLY=()
        ;;
    get)
        # get <filter>... — filters are +/- prefixed tokens and fmt=; hard to enumerate.
        COMPREPLY=($(compgen -W "++all ++named ++numbered ++selection ++@numbered ++@selection fmt=json fmt=table" -- "$cur"))
        ;;
    *)
        COMPREPLY=()
        ;;
    esac
}

complete -F _clipbender clipbender
