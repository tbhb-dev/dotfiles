#!/usr/bin/perl
# Refuse a Bash tool call that ends in a decorative echo of the exit status.
#
# A PreToolUse hook. Reads the payload on stdin, and answers with a deny
# envelope when the command's last action is an echo whose only job is to
# report the status of the work in front of it:
#
#     just lint 2>&1 | tail -30; echo "exit=${PIPESTATUS[0]}"
#
# Three things are wrong with that line. The harness already reports a
# command's exit status, so the echo is redundant when it works. The shell
# here is zsh, where the array is `pipestatus` and it is one-indexed, so the
# bash spelling expands to nothing and the line prints `exit=` whether the
# command passed or failed. Worst, a trailing echo always succeeds, so the
# compound command exits 0 and a failing lint run is reported as a pass.
#
# Mid-script uses of $? stay allowed: a conditional, a status captured and
# branched on, `exit $?` propagating the real code, a `|| echo` that runs
# only on failure. Only the trailing decorative form is refused. The case
# table under __DATA__ is where that line is drawn; run --self-test.
#
# Perl rather than Python because this runs in front of every Bash call and
# startup cost is the whole budget. /usr/bin/python3 on this machine costs
# ~1.5s per invocation (the Command Line Tools framework is pathologically
# slow to import `re`), which was measured as 1-3s of added latency per
# tool call. /usr/bin/perl with core JSON::PP costs ~60ms, is present on
# every macOS install, and needs no Homebrew or version manager on PATH.

use strict;
use warnings;
use JSON::PP ();

# Anything that names the status of the previous command. ${?} and $? are
# the portable spellings; PIPESTATUS and pipestatus are the bash and zsh
# arrays. The `$` sigil is required, so prose naming PIPESTATUS is no match.
my $STATUS = qr/\$\{\?\}|\$\?|\$\{?(?:PIPESTATUS|pipestatus)\b/;

# A segment whose whole job is printing. `command` and `builtin` prefixes
# are stripped because they change nothing about what follows.
my $ECHO = qr{^(?:command\s+|builtin\s+)?(?:echo|printf|print|/bin/echo)\b};

# NAME=value, with the shell's declaration keywords allowed in front.
my $ASSIGN = qr/^(?:local\s+|declare\s+|export\s+|typeset\s+|readonly\s+)?
                 ([A-Za-z_][A-Za-z0-9_]*)=(.*)$/x;

# A segment that tests something rather than printing it. `((` is arithmetic
# evaluation, which is a conditional in every practical use.
my $COND = qr/^(?:(?:if|elif|while|until|case|test)\b|\[\[?|\(\()/;

# The opening line of a here-document, whose body is data rather than shell.
my $HEREDOC = qr/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/;

# Redirection targets that consume output without storing it. Anything else
# after a `>` is a real file, which makes the echo a way of recording the
# status rather than decorating the transcript.
my %NON_FILE = map { $_ => 1 } qw(/dev/null /dev/stdout /dev/stderr /dev/tty);

# Kept deliberately short. A hook is stateless, so this is re-sent on every
# offending call rather than taught once. The long form cost 246 tokens a
# firing against the real tokenizer; this one costs 106 and says the same.
my $REASON =
    'Trailing exit-status echo: `%s`. Drop it, run the command alone. '
  . 'It is redundant (the harness reports exit status), it masks failure '
  . '(the echo always succeeds, so the compound exits 0), and PIPESTATUS is '
  . 'empty in zsh (it is `pipestatus`, 1-indexed). Branching on `$?` or '
  . '`exit $?` is still fine.';

sub trim {
    my ($s) = @_;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# Drop here-document bodies, which are data and not shell to parse.
sub strip_heredocs {
    my ($text) = @_;
    my @lines = split /\n/, $text, -1;
    my @kept;
    my $i = 0;
    while ( $i < @lines ) {
        my $line = $lines[$i];
        push @kept, $line;
        $i++;
        next unless $line =~ $HEREDOC;
        my $terminator = $2;
        $i++ while $i < @lines && trim( $lines[$i] ) ne $terminator;
        $i++;    # the terminator line itself is not shell either
    }
    return join "\n", @kept;
}

# Split a command into its top-level segments, as [separator, text] pairs.
# The separator is the operator that introduced the segment, empty for the
# first. Which operator joined a segment decides how it reads: an `|| echo`
# runs only on failure, which is error reporting rather than decoration.
#
# Quotes, command substitution, and subshells all suppress the split, so
# `bash -c 'a; b'` stays one segment and its inside is never mistaken for
# the caller's.
sub split_top_level {
    my ($text) = @_;
    my ( @segments, $quote );
    my ( $buf, $sep, $depth, $i ) = ( '', '', 0, 0 );
    my $n = length $text;

    while ( $i < $n ) {
        my $c = substr $text, $i, 1;

        if ( defined $quote ) {
            if ( $c eq "\\" && $quote ne "'" && $i + 1 < $n ) {
                $buf .= substr $text, $i, 2;
                $i += 2;
                next;
            }
            undef $quote if $c eq $quote;
            $buf .= $c;
            $i++;
            next;
        }

        if ( $c eq "\\" && $i + 1 < $n ) {
            $buf .= substr $text, $i, 2;
            $i += 2;
            next;
        }

        if ( $c eq q{'} || $c eq q{"} || $c eq '`' ) {
            $quote = $c;
            $buf .= $c;
            $i++;
            next;
        }

        if ( $c eq '(' || $c eq '{' ) {
            $depth++;
        }
        elsif ( $c eq ')' || $c eq '}' ) {
            $depth-- if $depth > 0;
        }
        elsif ( $depth == 0 ) {
            if ( $c eq ';' || $c eq "\n" ) {
                push @segments, [ $sep, $buf ];
                ( $buf, $sep ) = ( '', ';' );
                $i++;
                next;
            }
            my $two = substr $text, $i, 2;
            if ( $two eq '&&' || $two eq '||' ) {
                push @segments, [ $sep, $buf ];
                ( $buf, $sep ) = ( '', $two );
                $i += 2;
                next;
            }
        }

        $buf .= $c;
        $i++;
    }
    push @segments, [ $sep, $buf ];

    return [ grep { $_->[1] ne '' }
             map  { [ $_->[0], trim( $_->[1] ) ] } @segments ];
}

# Blank out `$( ... )` and backtick spans. A $? inside a command
# substitution is a value being captured, as in
# `echo "exit was: $(cmd >/dev/null; echo $?)"`. That reads a status the
# caller could not otherwise see, so it is a use rather than a decoration.
sub strip_substitutions {
    my ($text) = @_;
    my ( $out, $depth, $i ) = ( '', 0, 0 );
    my $n = length $text;
    while ( $i < $n ) {
        if ( substr( $text, $i, 2 ) eq '$(' ) {
            $depth++;
            $i += 2;
            next;
        }
        my $c = substr $text, $i, 1;
        if ( $depth && $c eq ')' ) {
            $depth--;
            $i++;
            next;
        }
        if ( $c eq '`' ) {
            $i++;
            $i++ while $i < $n && substr( $text, $i, 1 ) ne '`';
            $i++;
            next;
        }
        $out .= $c unless $depth;
        $i++;
    }
    return $out;
}

# Report whether the segment sends its output to a real file. An echo
# written to a file is recording the status for something later to read,
# which is a use rather than a decoration. Descriptor duplication (`>&2`)
# and the discard targets are not files.
sub redirects_to_file {
    my ($segment) = @_;
    my ( $quote, $i ) = ( undef, 0 );
    my $n = length $segment;
    while ( $i < $n ) {
        my $c = substr $segment, $i, 1;
        if ( defined $quote ) {
            if ( $c eq "\\" && $quote ne "'" && $i + 1 < $n ) { $i += 2; next }
            undef $quote if $c eq $quote;
            $i++;
            next;
        }
        if ( $c eq "\\" && $i + 1 < $n ) { $i += 2; next }
        if ( $c eq q{'} || $c eq q{"} || $c eq '`' ) { $quote = $c; $i++; next }
        if ( $c eq '>' ) {
            $i++;
            $i++ if $i < $n && substr( $segment, $i, 1 ) eq '>';
            $i++ while $i < $n && substr( $segment, $i, 1 ) =~ /[ \t]/;
            my $target = '';
            while ( $i < $n && substr( $segment, $i, 1 ) !~ /[ \t|;&]/ ) {
                $target .= substr $segment, $i, 1;
                $i++;
            }
            return 1
              if length $target
              && index( $target, '&' ) != 0
              && !$NON_FILE{$target};
            next;
        }
        $i++;
    }
    return 0;
}

# Collect variables assigned from the exit status, such as `rc=$?`.
sub status_variables {
    my ($segments) = @_;
    my %names;
    for my $pair (@$segments) {
        next unless $pair->[1] =~ $ASSIGN;

        # Bind before the next match: testing $value would reset $1 first,
        # leaving an empty name whose \Q\E matches every `$var` expansion.
        my ( $name, $value ) = ( $1, $2 );
        $names{$name} = 1 if $value =~ $STATUS;
    }
    return \%names;
}

# Report whether the text expands any of the given variables.
sub references {
    my ( $text, $names ) = @_;
    for my $name ( keys %$names ) {
        return 1 if $text =~ /\$\{?\Q$name\E\b/;
    }
    return 0;
}

# Report whether any segment tests the status rather than printing it. One
# conditional anywhere is enough to hand the whole command back. A command
# that already inspects its own status is doing deliberate error handling,
# and guessing which of its several $? reads is decorative would cost more
# false positives than the rule is worth.
sub branches_on_status {
    my ( $segments, $names ) = @_;
    for my $pair (@$segments) {
        next unless $pair->[1] =~ $COND;
        return 1 if $pair->[1] =~ $STATUS || references( $pair->[1], $names );
    }
    return 0;
}

# Return the trailing decorative status echo, or undef if there is none.
# undef is the answer for everything ambiguous. This gate sits in front of
# every Bash call, so a rule that is unsure must let the call through.
sub offending_tail {
    my ($command) = @_;
    my $segments = split_top_level( strip_heredocs($command) );

    # Nothing in front of it, so there is no status being masked. A lone
    # `echo $?` reads a status from a shell that just started.
    return undef if @$segments < 2;

    my ( $sep, $tail ) = @{ $segments->[-1] };

    # `cmd && echo PASS || echo "FAIL($?)"` branches on the status. The echo
    # runs only on failure, which is reporting rather than decorating.
    return undef if $sep eq '||';
    return undef unless $tail =~ $ECHO;
    return undef if redirects_to_file($tail);

    my @leading = @{$segments}[ 0 .. $#$segments - 1 ];
    my $names   = status_variables( \@leading );
    my $visible = strip_substitutions($tail);

    return undef unless $visible =~ $STATUS || references( $visible, $names );
    return undef if branches_on_status( $segments, $names );
    return $tail;
}

sub run_hook {
    my $raw = do { local $/; <STDIN> };
    return unless defined $raw && length $raw;
    my $payload = JSON::PP->new->decode($raw);
    return unless ( $payload->{tool_name} // '' ) eq 'Bash';
    my $command = $payload->{tool_input}{command};
    return unless defined $command;
    my $tail = offending_tail($command);
    return unless defined $tail;
    print JSON::PP->new->canonical->encode(
        {   hookSpecificOutput => {
                hookEventName            => 'PreToolUse',
                permissionDecision       => 'deny',
                permissionDecisionReason => sprintf( $REASON, $tail ),
            }
        }
    ), "\n";
    return;
}

# Cases the rule is written against, read from __DATA__ so no shell quoting
# has to survive a Perl string literal. A literal \n in a case becomes a
# newline; everything else is taken verbatim.
sub load_cases {
    my ( @deny, @allow );
    my $bucket;
    while ( my $line = <DATA> ) {
        chomp $line;
        next if $line =~ /^\s*$/ || $line =~ /^#/;
        if    ( $line eq '[deny]' )  { $bucket = \@deny;  next }
        elsif ( $line eq '[allow]' ) { $bucket = \@allow; next }
        $line =~ s/\\n/\n/g;
        push @$bucket, $line;
    }
    return ( \@deny, \@allow );
}

sub self_test {
    my ( $deny, $allow ) = load_cases();
    my @failures;
    for my $case (@$deny) {
        push @failures, [ 'expected deny, got allow', $case ]
          unless defined offending_tail($case);
    }
    for my $case (@$allow) {
        my $tail = offending_tail($case);
        push @failures, [ "expected allow, denied on '$tail'", $case ]
          if defined $tail;
    }
    printf "FAIL: %s\n      %s\n", @$_ for @failures;
    my $total = @$deny + @$allow;
    printf "%d/%d cases pass\n", $total - @failures, $total;
    return @failures ? 1 : 0;
}

if ( grep { $_ eq '--self-test' } @ARGV ) {
    exit self_test();
}

# A gate in front of every Bash call must never block on its own
# malfunction. Any failure to read or judge the payload is an allow.
eval { run_hook(); 1 } or exit 0;
exit 0;

__DATA__
[deny]
just lint-commit-msg 2>&1 | tail -30; echo "exit=${PIPESTATUS[0]}"
just lint; echo "exit=$?"
go test ./... && echo "exit=$?"
make build\necho "exit code: $?"
npm run lint; rc=$?; echo $rc
cargo build; echo $?
pytest; echo "status: $?"
ruff check .; printf 'exit=%d\n' $?
go vet ./...; echo "exit=${?}"
cmd | tail -20; echo "exit=$pipestatus[1]"
cmd; STATUS=$?; echo "STATUS=$STATUS"
cmd; echo "exit=$?" >&2
cmd; echo "---"; echo "exit=$?"
cmd; echo exit=$?
cmd; echo "exit=$?" > /dev/null
set -o pipefail\njust lint 2>&1 | tail -5\necho "rc=$?"
cmd; echo "exit=$?" | tee -a run.log
# Label forms observed in this account's own transcripts. The label is
# unconstrained: any tool name, any decoration, or none at all.
apm install 2>&1 | tail -20; echo "EXIT=$?"
just lint 2>&1 | tail -25; echo "EXIT=${PIPESTATUS[0]}"
just lint 2>&1 | tail -40; echo "EXIT=${pipestatus[1]}"
vale --output=line README.md; echo "exit: $?"
just lint-shell; echo "recipe exit=$?"
just merge-guard proto/x 2>&1 | tail -15 && echo "GUARD_EXIT=$?"
just lint 2>&1 | tail -40; echo "EXIT:$?"
cspell lint .; echo "cspell:$?"
just lint-pkg x 2>&1 | tail -5\necho "=== rc=$? ==="
just test; echo "--- exit $?"
just lint; echo "(exit $?)"
prek run --all-files; echo "prek=$?"

[allow]
# Branching on the status is the legitimate use.
cmd; if [ $? -ne 0 ]; then echo "failed"; exit 1; fi
cmd; rc=$?; if [ $rc -ne 0 ]; then echo "failed: $rc"; fi; exit $rc
[ $? -eq 0 ] || echo "failed"
cmd; test $? -eq 0 && echo ok || echo "broken: $?"
cmd; rc=$?; [ $rc -eq 0 ] && echo pass; exit $rc
# Propagating the status rather than swallowing it.
cmd; exit $?
cmd; rc=$?; exit $rc
# No status reference at all.
go build ./... && echo "done"
echo "exit"
git status --short; git log --oneline -3
cmd; echo "PIPESTATUS is a bash array, unlike zsh"
# Echoing an ordinary variable is not echoing a status. Regression: an
# empty captured name once made \Q\E match every $var expansion here.
out=$(git branch --show-current); echo "$out"
cmd; echo $HOME
just build; echo "built $TARGET"
# A status echo that is not the last thing, so nothing is masked.
cmd; echo "exit=$?"; git status --short
# Nothing in front of it to mask.
echo $?
# The pattern as data rather than as shell.
cat > run.sh <<'EOF'\nset -e\ncmd\necho "exit=$?"\nEOF
echo 'cmd; echo "exit=$?"' > snippet.txt
bash -c 'cmd; echo "exit=$?"'
rg -n 'echo \$\?' .
cmd; echo "exit=$?" > status.txt
# Loop and function bodies, where the echo is not the tail.
for f in a b; do echo $?; done
cmd; while read -r l; do echo $?; done < f
# Not an echo at all.
cmd; rc=$?
just lint 2>&1 | tail -30
# Counter-examples drawn from this account's own transcripts.
just lint-config >/dev/null 2>&1 && echo "PASS" || echo "FAIL($?)"
docker info >/dev/null 2>&1 && echo "docker OK" || echo "not running (exit $?)"
cd wt; echo "exit was: $(just lint-config >/dev/null 2>&1; echo $?)"
out=$(just lint 2>&1); rc=$?; echo "exit=$rc"; [ $rc -ne 0 ] && echo "$out" | head -30
for g in a b; do out=$(uv run $g 2>&1); if [ $? -eq 0 ]; then echo PASS; else echo FAIL; fi; done
run() { bash "$G" >/dev/null 2>&1; echo $?; }; printf "%s\n" "$(run "git add -A")"
printf 'grep -q foo bar\nif [ $? -eq 0 ]; then\n echo yes\nfi\n' > t.sh && shellcheck t.sh
(just lint-editorconfig; echo "exit=$?"); cp /tmp/jf.bak Justfile && echo 'restored'
apm audit --ci 2>&1 | tail -8; echo "=== status ==="; git status --short | head -30
