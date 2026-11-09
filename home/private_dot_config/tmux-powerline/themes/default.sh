# shellcheck shell=bash
# Custom Theme — Monokai Pro palette with pill-style segments
#
# Monokai Pro colors:
#   bg:      #2d2a2e    surface: #403e41    dimmed: #727072
#   fg:      #fcfcfa    grey:    #959394
#   red:     #ff6188    orange:  #fc9867    yellow: #ffd866
#   green:   #a9dc76    cyan:    #78dce8    purple: #ab9df2

if tp_patched_font_in_use; then
	TMUX_POWERLINE_SEPARATOR_LEFT_BOLD=""
	TMUX_POWERLINE_SEPARATOR_LEFT_THIN=""
	TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD=""
	TMUX_POWERLINE_SEPARATOR_RIGHT_THIN=""
else
	TMUX_POWERLINE_SEPARATOR_LEFT_BOLD="◀"
	TMUX_POWERLINE_SEPARATOR_LEFT_THIN="❮"
	TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD="▶"
	TMUX_POWERLINE_SEPARATOR_RIGHT_THIN="❯"
fi

TMUX_POWERLINE_DEFAULT_BACKGROUND_COLOR=${TMUX_POWERLINE_DEFAULT_BACKGROUND_COLOR:-'default'}
TMUX_POWERLINE_DEFAULT_FOREGROUND_COLOR=${TMUX_POWERLINE_DEFAULT_FOREGROUND_COLOR:-'#fcfcfa'}
# shellcheck disable=SC2034
TMUX_POWERLINE_SEG_AIR_COLOR=$(tp_air_color)

TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR=${TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR:-$TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}
TMUX_POWERLINE_DEFAULT_RIGHTSIDE_SEPARATOR=${TMUX_POWERLINE_DEFAULT_RIGHTSIDE_SEPARATOR:-$TMUX_POWERLINE_SEPARATOR_LEFT_BOLD}

# Active window pill — green bg, dark text
# shellcheck disable=SC2128
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_CURRENT" ]; then
	TMUX_POWERLINE_WINDOW_STATUS_CURRENT=(
		"#[fg=#a9dc76,bg=default]"
		"${TMUX_POWERLINE_SEPARATOR_LEFT_BOLD}"
		"#[fg=#2d2a2e,bg=#a9dc76,bold]"
		"#I"
		"#[fg=#a9dc76,bg=#8ab866,nobold]"
		"${TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}"
		"#[fg=#2d2a2e,bg=#8ab866] #W"
		"#[fg=#8ab866,bg=default]"
		"${TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}"
	)
fi

# shellcheck disable=SC2128
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_STYLE" ]; then
	TMUX_POWERLINE_WINDOW_STATUS_STYLE=(
		"$(tp_format regular)"
	)
fi

# Inactive window pill — surface bg, dimmed text
# shellcheck disable=SC2128
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_FORMAT" ]; then
	TMUX_POWERLINE_WINDOW_STATUS_FORMAT=(
		"#[fg=#403e41,bg=default]"
		"${TMUX_POWERLINE_SEPARATOR_LEFT_BOLD}"
		"#[fg=#959394,bg=#403e41]"
		"#I"
		"#[fg=#403e41,bg=#4a474b]"
		"${TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}"
		"#[fg=#959394,bg=#4a474b] #W"
		"#[fg=#4a474b,bg=default]"
		"${TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}"
	)
fi

# Left: hostname (cyan), session (purple)
# shellcheck disable=SC1143,SC2128
if [ -z "$TMUX_POWERLINE_LEFT_STATUS_SEGMENTS" ]; then
	TMUX_POWERLINE_LEFT_STATUS_SEGMENTS=(
		"left_cap default #78dce8 default_separator no_sep_bg_color no_sep_fg_color both_disable separator_disable"
		"hostname #78dce8 #2d2a2e"
		"tmux_session_info #ab9df2 #2d2a2e"
	)
fi

# Right: load (orange), battery (yellow), date+time (surface)
# shellcheck disable=SC1143,SC2128
if [ -z "$TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS" ]; then
	TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS=(
		"cpu_total #403e41 #fc9867 default_separator no_sep_bg_color no_sep_fg_color left_disable no_separator_disable"
		"mem_percent #403e41 #fc9867 default_separator no_sep_bg_color no_sep_fg_color left_disable separator_disable"
		"date #403e41 #959394 default_separator no_sep_bg_color no_sep_fg_color left_disable separator_disable"
		"time #403e41 #959394 default_separator no_sep_bg_color no_sep_fg_color both_disable separator_disable"
		"right_cap default #403e41 default_separator no_sep_bg_color no_sep_fg_color both_disable separator_disable"
	)
fi
