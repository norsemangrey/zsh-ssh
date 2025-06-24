#!/usr/bin/env zsh

# Better completion for SSH in ZSH
# https://github.com/norsemangrey/zsh-ssh
# v0.0.1

setopt no_beep # don't beep

SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-$HOME/.ssh/config}"

# Parse the file and handle the include directive.
_parse_config_file() {

  # Enable PCRE matching and handle local options
  setopt localoptions rematchpcre
  unsetopt nomatch

  # Resolve the full path of the input config file
  local config_file_path=$(realpath -e "$1")

  # Read the file line by line
  while IFS= read -r line || [[ -n "$line" ]]; do

    # Match lines starting with 'Include'
    if [[ $line =~ ^[Ii]nclude[[:space:]]+(.*) ]] && (( $#match > 0 )); then

      # Split the rest of the line into individual paths
      local include_paths=(${(z)match[1]})

      for raw_path in "${include_paths[@]}"; do

        # Expand ~ and environment variables in the path
        eval "local expanded=\${(e)raw_path}"

        # If path is relative, resolve it relative to the current config file
        if [[ "$expanded" != /* ]]; then

          expanded="$HOME/.ssh/$expanded"

        fi

        # Expand wildcards (e.g. *.conf) and loop over each matched file
        for include_file_path in $~expanded; do

          if [[ -f "$include_file_path" ]]; then

            local real_include_path

            real_include_path=$(realpath -e "$include_file_path") || {

              continue

            }

            echo ""

            # Recursively parse included files
            _parse_config_file "$real_include_path"

          fi

        done

      done

    else

      # Print normal (non-Include) lines
      echo "$line"

    fi

  # Input redirection to read file
  done < "$config_file_path"

}

# Generate a list of SSH hosts by parsing config files
_ssh_host_list() {

  local ssh_config host_list

  # Parse SSH config while removing regular comment lines (preserve #_ metadata comments)
  ssh_config=$(_parse_config_file $SSH_CONFIG_FILE)

  # Remove lines like # comment
  ssh_config=$(echo $ssh_config | command grep -v -E "^\s*#[^_]")

  host_list=$(echo $ssh_config | command awk '
    function join(array, start, end, sep, result, i) {
      # https://www.gnu.org/software/gawk/manual/html_node/Join-Function.html
      if (sep == "")
        sep = " "
      else if (sep == SUBSEP) # magic value
        sep = ""
      result = array[start]
      for (i = start + 1; i <= end; i++)
        result = result sep array[i]
      return result
    }

    function parse_line(line) {
      n = split(line, line_array, " ")

      key = line_array[1]
      value = join(line_array, 2, n)

      return key "#-#" value
    }

    function contains_star(str) {
        return index(str, "*") > 0
    }

    function starts_or_ends_with_star(str) {
        start_char = substr(str, 1, 1)
        end_char = substr(str, length(str), 1)

        return start_char == "*" || end_char == "*"
    }

    BEGIN {
      IGNORECASE = 1
      FS="\n"
      RS=""

      host_list = ""
    }
    {
      match_directive = ""

      # Use spaces to ensure the column command maintains the correct number of columns.
      #   - user
      #   - desc_formated

      user = " "
      host_name = ""
      alias = ""
      desc = ""
      desc_formated = " "

      for (line_num = 1; line_num <= NF; ++line_num) {
        line = parse_line($line_num)

        split(line, tmp, "#-#")

        key = tolower(tmp[1])
        value = tmp[2]

        if (key == "match") { match_directive = value }

        if (key == "host") { aliases = value }
        if (key == "user") { user = value }
        if (key == "hostname") { host_name = value }
        if (key == "#_desc") { desc = value }
      }

      split(aliases, alias_list, " ")
      for (i in alias_list) {
        alias = alias_list[i]

        if (!host_name && alias ) {
          host_name = alias
        }

        if (desc) {
          desc_formated = sprintf("[\033[00;34m%s\033[0m]", desc)
        }

        if ((host_name && !starts_or_ends_with_star(host_name)) && (alias && !starts_or_ends_with_star(alias)) && !match_directive) {
          host = sprintf("%s|->|%s|%s|%s\n", alias, host_name, user, desc_formated)
          host_list = host_list host
        }
      }
    }
    END {
      print host_list
    }
  ')

  # Extract and clean command-line arguments for host filterin
  for arg in "$@"; do

    case $arg in
    -*) shift;;
    *) break;;
    esac

  done

  # Filter hosts by search string

  # Case-insensitive filter
  host_list=$(command grep -i "$1" <<< "$host_list")

  # Deduplicate entries
  host_list=$(echo $host_list | command sort -u)

  # Return filtered list
  echo $host_list

}

# Format host list into fzf-compatible table format
_fzf_list_generator() {

  local header host_list

  if [ -n "$1" ]; then

    # Use provided host list
    host_list="$1"

  else

    # Fallback: generate from config
    host_list=$(_ssh_host_list)

  fi

  # Display header and host data as a formatted table
  header="
Alias|->|Hostname|User|Desc
─────|──|────────|────|────
"

  host_list="${header}\n${host_list}"

  # Align columns using '|' as delimiter
  echo $host_list | command column -t -s '|'

}

_set_lbuffer() {

  local result selected_host connect_cmd is_fzf_result

  result="$1"
  is_fzf_result="$2"

  if [ "$is_fzf_result" = false ] ; then

    # Extract alias
    result=$(cut -f 1 -d "|" <<< ${result})

  fi

  # Sanitize whitespace
  selected_host=$(cut -f 1 -d " " <<< ${result})

  connect_cmd="ssh ${selected_host}"

  # Inject into shell input
  LBUFFER="$connect_cmd"

}

# Override SSH tab completion with fzf interface
fzf_complete_ssh() {

  local tokens cmd result selected_host

  setopt localoptions noshwordsplit noksh_arrays noposixbuiltins

  # Split input line into words
  tokens=(${(z)LBUFFER})

  # First word (expected to be 'ssh')
  cmd=${tokens[1]}

  if [[ "$LBUFFER" =~ "^ *ssh$" ]]; then

    # Fallback: normal tab-complete
    zle ${fzf_ssh_default_completion:-expand-or-complete}

  elif [[ "$cmd" == "ssh" ]]; then

    # Lookup with partial input
    result=$(_ssh_host_list ${tokens[2, -1]})

    # Extract search query
    fuzzy_input="${LBUFFER#"$tokens[1] "}"

    if [ -z "$result" ]; then

      # Fallback: no matches
      zle ${fzf_ssh_default_completion:-expand-or-complete}

      return

    fi

    if [ $(echo $result | wc -l) -eq 1 ]; then

      # Auto-complete if exactly one match
      _set_lbuffer $result false

      zle reset-prompt

      # zle redisplay

      return

    fi

    # Launch FZF interactive selector
    result=$(_fzf_list_generator $result | fzf \
      --height 40% \
      --ansi \
      --border \
      --cycle \
      --info=inline \
      --header-lines=2 \
      --reverse \
      --prompt='SSH Remote > ' \
      --query=$fuzzy_input \
      --no-separator \
      --bind 'shift-tab:up,tab:down,bspace:backward-delete-char/eof' \
      --preview 'ssh -T -G $(cut -f 1 -d " " <<< {}) | grep -i -E "^User |^HostName |^Port |^ControlMaster |^ForwardAgent |^LocalForward |^IdentityFile |^RemoteForward |^ProxyCommand |^ProxyJump " | column -t' \
      --preview-window=right:40%
    )

    if [ -n "$result" ]; then

      # Set buffer with selected result
      _set_lbuffer $result true

      # Submit command
      zle accept-line

    fi

    zle reset-prompt

    # zle redisplay

  # Fall back to default completion
  else

    # Fallback
    zle ${fzf_ssh_default_completion:-expand-or-complete}

  fi

}

# Backup current tab-completion binding if not already saved
[ -z "$fzf_ssh_default_completion" ] && {

  # Capture current binding for tab key
  binding=$(bindkey '^I')

  # Store function name
  [[ $binding =~ 'undefined-key' ]] || fzf_ssh_default_completion=$binding[(s: :w)2]

  unset binding

}

# Hook the function into tab key

# Register ZLE function
zle -N fzf_complete_ssh

# Bind tab key to our fuzzy completion
bindkey '^I' fzf_complete_ssh

# vim: set ft=zsh sw=2 ts=2 et
