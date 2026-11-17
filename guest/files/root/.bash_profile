[ -f ~/.bashrc ] && . ~/.bashrc
PS1='\[\e[1;34m\]\w\[\e[0m\] \$ '
alias ls='ls --color=auto' grep='grep --color=auto' ll='ls -lh'
[ "$SHLVL" = 1 ] && fastfetch
