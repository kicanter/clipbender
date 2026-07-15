# fish completion for clipbender
# Install: drop this file in ~/.config/fish/completions/ or /usr/share/fish/vendor_completions.d/

# Only offer subcommands as the first argument.
complete -c clipbender -n '__fish_use_subcommand' -a set -d 'Set a register or the system selection'
complete -c clipbender -n '__fish_use_subcommand' -a get -d 'Print register contents'
complete -c clipbender -n '__fish_use_subcommand' -a clear -d 'Clear a named register'
complete -c clipbender -n '__fish_use_subcommand' -a shutdown -d 'Stop the clipbenderd daemon'

# `set` destination/source keywords.
complete -c clipbender -n '__fish_seen_subcommand_from set' -a 'clipboard primary' -d 'System selection'

# `get` filter tokens.
complete -c clipbender -n '__fish_seen_subcommand_from get' \
    -a '++all ++named ++numbered ++selection ++@numbered ++@selection fmt=json fmt=table' \
    -d 'Register filter'
