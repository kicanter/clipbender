# nushell completion for clipbender
# Install: source this file from your config.nu, e.g. `source /path/to/clipbender.nu`

def "nu-complete clipbender subcommands" [] {
    [
        { value: "set",      description: "Set a register or the system selection" }
        { value: "get",      description: "Print register contents" }
        { value: "clear",    description: "Clear a named register" }
        { value: "shutdown", description: "Stop the clipbenderd daemon" }
    ]
}

def "nu-complete clipbender targets" [] {
    ["clipboard" "primary"]
}

def "nu-complete clipbender get-filters" [] {
    ["++all" "++named" "++numbered" "++selection" "++@numbered" "++@selection" "fmt=json" "fmt=table"]
}

# Top-level `clipbender` command. Bare invocation opens the popup.
export extern "clipbender" [
    subcommand?: string@"nu-complete clipbender subcommands"
    ...args: string
]

export extern "clipbender set" [
    destination: string@"nu-complete clipbender targets"  # a-z, A-Z, clipboard, primary
    source?: string@"nu-complete clipbender targets"       # 0-9, a-z, @0-@9, clipboard, primary
]

export extern "clipbender get" [
    ...filters: string@"nu-complete clipbender get-filters"
]

export extern "clipbender clear" [
    register: string  # named register a-z
]

export extern "clipbender shutdown" []
