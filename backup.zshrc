# Add deno completions to search path
if [[ ":$FPATH:" != *":/home/alex/.zsh/completions:"* ]]; then export FPATH="/home/alex/.zsh/completions:$FPATH"; fi
# https://zsh.sourceforge.io/Intro/intro_6.html https://zsh.sourceforge.io/Doc/Release/Functions.html#Functions
# https://www.digitalocean.com/community/tutorials/how-to-use-editors-regex-and-hooks-with-z-shell#respond-to-events-with-hooks
# ======================= OH-MY-ZSH =======================
export PATH="$PATH:$HOME/.nvim/bin:$HOME/.deno/bin:$HOME/.bun/bin:$HOME/.pyenv/bin:$HOME/.local/go/bin:$HOME/.juliaup/bin:$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.rbenv/bin:$HOME/.atuin/bin:$HOME/.awscliv2/binaries"
export ZSH="$HOME/.oh-my-zsh"
export ZSH_THEME="robbyrussell"
plugins=(git terraform zsh-syntax-highlighting zsh-autosuggestions)
source $ZSH/oh-my-zsh.sh
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
# ======================= ENV =======================
#\. "$NVM_DIR/nvm.sh" # NODE
\. "$HOME/.cargo/env" # RUST
eval "$(~/.rbenv/bin/rbenv init - --no-rehash zsh)" && autoload -U compinit && compinit # RUBY
eval "$(atuin init zsh --disable-up-arrow --disable-ctrl-r)" # ATUIN
eval "$(starship init zsh)" # STARSHIP
# ======================= ALIASES =======================
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
alias skl='sudo systemctl stop tlp;sudo sysctl vm.swappiness=10;sudo cpupower frequency-set -g performance;gamemoderun java -jar ~/Desktop/SKlauncher-3.2.18.jar --workDir /games/minecraft'
alias reboot="systemctl reboot"
alias media="/usr/bin/media.sh"
alias logoff='dbus-send --session --type=method_call --print-reply --dest=org.gnome.SessionManager /org/gnome/SessionManager org.gnome.SessionManager.Logout uint32:1'

nohup python3 wallchange.py > /dev/null 2>&1 &
# Disable NVIDIA driver for better iGPU performance
# rd.driver.blacklist=nouveau nouveau.modeset=0
. "/home/fred/.deno/env"

# bun completions
[ -s "/home/fred/.bun/_bun" ] && source "/home/fred/.bun/_bun"
