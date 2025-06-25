#!/usr/bin/env zsh

# Better completion for SSH in ZSH
# https://github.com/norsemangrey/zsh-ssh
# v0.0.1

# Default SSH config file location
# Can be overridden by setting SSH_CONFIG_FILE environment variable
SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-$HOME/.ssh/config}"

# Function to recursively parse an SSH config file and its Include directives
# $1: Path to the SSH config file to parse
_parse_config_file() {

    # Ensure local options are set for this function
  setopt localoptions # Make option changes local to the function or script
  setopt rematchpcre  # Use PCRE for regular expressions

  # Avoids errors when a glob does not match any file
  unsetopt nomatch

  # Resolve the full path of the SSH config file
  local config_file_path=$(realpath -e "$1")

  # Read the file line by line
  while IFS= read -r line || [[ -n "${line}" ]]; do

    # Check if the line contains an 'Include' directive
    if [[ $line =~ ^[Ii]nclude[[:space:]]+(.*) ]] && (( $#match > 0 )); then

      # Split the rest of the line into individual paths
      local include_paths=(${(z)match[1]})

      for raw_path in "${include_paths[@]}"; do

        # Expand ~ and environment variables in the path using (e)
        local expanded_path=${(e)raw_path}

        # If path is relative, resolve it relative to ~/.ssh
        [[ "${expanded_path}" != /* ]] && expanded_path="$HOME/.ssh/${expanded_path}"

        # Expand wildcards (e.g. *.conf) and loop over each matched file
        for include_file_path in $~expanded_path; do

          # Check if the file exists before processing
          [[ -f "${include_file_path}" ]] || continue

          local real_include_path

          # Resolve the real path of the included file
          real_include_path=$(realpath -e "${include_file_path}" 2>/dev/null) || continue

          echo ""

          # Recursively parse included files
          _parse_config_file "${real_include_path}"

        done

      done

    else

      # Print normal (non-Include) lines
      echo "${line}"

    fi

  done < "${config_file_path}"

}

# Generate a list of SSH hosts by parsing config files
_ssh_host_list() {

  local ssh_config host_list

  # Parse SSH config while removing regular comment lines (preserve #_ metadata comments)
  ssh_config=$(_parse_config_file "$SSH_CONFIG_FILE")

  # Remove lines like # comment
  ssh_config=$(printf "%s\n" "${ssh_config}" | grep -v -E "^\s*#[^_]")

  # Extract host entries from the SSH config
  host_list=$(awk '
    tolower($1) == "host"     { host=$2 }
    tolower($1) == "hostname" { hostname=$2 }
    tolower($1) == "user"     { user=$2 }
    /^[[:space:]]*$/ && host && hostname {
      print host "|->|" hostname "|" user
      host=hostname=user=""
    }
  ' <<< "${ssh_config}")

  # Extract and clean command-line arguments for host filtering
  for arg in "$@"; do
    case $arg in
    -*) shift;;
    *) break;;
    esac
  done

  # Filter entries based on all arguments passed to the function (multi-keyword search)
  for arg in "$@"; do
    host_list=$(printf "%s\n" "${host_list}" | grep -i "${arg}")
  done

  # Deduplicate entries
  host_list=$(echo $host_list | command sort -u)

  # Return filtered list
  echo "${host_list}"
}

# Format host list into fzf-compatible table format
_fzf_list_generator() {

  # Declare local variables
  local header host_list

  # Check if a host list was provided as an argument
  if [ -n "$1" ]; then

    # Use provided host list
    host_list="$1"

  else

    # Generate host list from SSH config
    host_list=$(_ssh_host_list)

  fi

  # Display header and host data as a formatted table
  header="
Alias|->|Hostname|User|Desc
─────|──|────────|────|────
"

  # Add header to the host list
  host_list="${header}
${host_list}"

  # Align columns using '|' as delimiter
  printf "%s\n" "${host_list}" | column -t -s '|'

}

_set_lbuffer() {

  # Declare local variables
  local result selected_host connect_cmd is_fzf_result

  # Get host list and passed flag
  result="$1"
  is_fzf_result="$2"

  # Check if result is from FZF
  if [ "${is_fzf_result}" = false ] ; then

    # Extract alias
    result=$(cut -f 1 -d "|" <<< ${result})

  fi

  # Sanitize whitespace and get hostname only
  selected_host=$(cut -f 1 -d " " <<< ${result})

  # Build the SSH connect command
  connect_cmd="ssh ${selected_host}"

  # Inject into shell input
  LBUFFER="${connect_cmd}"

}

# Override SSH tab completion with fzf interface
fzf_complete_ssh() {

  # Declare local variables
  local tokens cmd result selected_host

  # Ensure local options are set for this function
  setopt localoptions     # Make option changes local to the function or script
  setopt noshwordsplit    # Disable word splitting on unquoted parameter expansions
  setopt noksh_arrays     # Use ZSH array behavior instead of KSH-style arrays
  setopt noposixbuiltins  # Use ZSH built-ins, not POSIX-compatible versions

  # Ensure FZF exists
  command -v fzf >/dev/null || return

  # Split input line into words
  # The LBUFFER variable contains the current command line input
  tokens=(${(z)LBUFFER})

  # First word (expected to be 'ssh')
  cmd=${tokens[1]}

  # Check that the input is not just 'ssh' (with optional leading spaces)
  if [[ "${LBUFFER}" =~ "^ *ssh$" ]]; then

    # If so fallback to default completion
    zle ${fzf_ssh_default_completion:-expand-or-complete}

  # Check that the fist word in the input is 'ssh'
  elif [[ "${cmd}" == "ssh" ]]; then

    # Generate the SSH host list with optional filtering
    result=$(_ssh_host_list ${tokens[2, -1]})

    # Extract search query
    fuzzy_input="${LBUFFER#"${cmd} "}"

    # Check if the resulting SSH host list is empty
    if [ -z "${result}" ]; then

      # If so fallback to default completion
      zle ${fzf_ssh_default_completion:-expand-or-complete}

      return

    fi

    # If only one match, set it directly
    if [ $(printf "%s\n" "${result}" | wc -l) -eq 1 ]; then

      # Auto-complete if exactly one match
      # Calls the helper function to set the buffer
      _set_lbuffer "${result}" false

      # Submit command, ensuring it is displayed
      zle reset-prompt

      return

    fi

    # Define preview grep fields
    local preview_fields="^User |^HostName |^Port |^ControlMaster |^ForwardAgent |^LocalForward |^IdentityFile |^RemoteForward |^ProxyCommand |^ProxyJump "

    # Launch FZF interactive selector with various options
    result=$(_fzf_list_generator "${result}" | fzf \
      --height 40% \
      --ansi \
      --border \
      --cycle \
      --info=inline \
      --header-lines=2 \
      --reverse \
      --prompt='SSH Remote > ' \
      --query="${fuzzy_input}" \
      --no-separator \
      --bind 'shift-tab:up,tab:down,bspace:backward-delete-char/eof' \
      --preview "ssh -T -G \$(cut -f 1 -d ' ' <<< {}) | grep -i -E \"${preview_fields}\" | column -t" \
      --preview-window=right:40%
    )

    # Check if a item from the list was selected
    if [ -n "${result}" ]; then

      # Set buffer with selected result
      _set_lbuffer "${result}" true

      # Accept the line to execute the command
      zle accept-line

    fi

    # Reset the prompt to ensure it updates correctly
    zle reset-prompt

  # Fall back to default completion
  else

    # If not 'ssh', use default completion
    zle ${fzf_ssh_default_completion:-expand-or-complete}

  fi
}

# Backup current tab-completion binding if not already saved
[ -z "$fzf_ssh_default_completion" ] && {

  # Save the current binding for TAB key
  binding=$(bindkey '^I')

  # Check if the binding is not already set to 'undefined-key' and extract the completion command
  [[ $binding =~ 'undefined-key' ]] || fzf_ssh_default_completion=$binding[(s: :w)2]

  # If binding is not set, use default completion
  unset binding

}

# Hook the function into TAB key

# Register ZLE function
# This allows us to use the function in ZSH's line editor
zle -N fzf_complete_ssh

# Bind TAB key to our fuzzy completion
bindkey '^I' fzf_complete_ssh
