#!/usr/bin/perl
# Quote a bare run of `=` so zsh does not try to expand it into a path.
#
# A PreToolUse hook. Reads the payload on stdin, and answers with an
# updatedInput envelope when a command uses an unquoted `===` as a separator:
#
#     sed -n '5,40p' a.md; echo ===; sed -n '655,680p' b.md
#
# zsh's EQUALS option is on by default here, so a word beginning with `=`
# expands to the path of the command named after it -- `=ls` becomes
# /opt/homebrew/.../ls. A word that is nothing but equals signs names the
# command `==`, which does not exist:
#
#     zsh:1: == not found
#
# The failure is worth a hook because of where it lands. The word is never
# reached as an argument; the whole command aborts at that point with status
# 127, so the second `sed` above never runs. What comes back is the first
# chunk of output and no indication that the rest was dropped, which reads
# exactly like a file that was shorter than expected. It was 87 occurrences
# across 26 sessions of the transcripts this hook was written from -- spread
# evenly, not clustered, so it is a standing habit rather than one bad day.
#
# Quoting is the whole fix, and it is unambiguous: equals-expansion of a
# pure-equals word has no successful outcome, so a `===` that reaches the
# shell unquoted is always a mistake. `--flag===x` and `a===b` are untouched
# because expansion only applies at the start of a word, and a lone `=` is
# left alone because it has no command name after it and so never expands.
#
# `[[ ... ]]` is excluded. There `==` is the comparison operator, it is not
# subject to filename expansion, and quoting it is what would break it:
#
#     zsh:1: condition expected: "=="
#
# `(( ... ))` is excluded on the same reasoning. Single-bracket `[ x == x ]`
# is NOT excluded -- it fails unquoted like any other command argument, and
# quoting fixes it, because `[` is an ordinary builtin taking ordinary words.
#
# Perl for the same reason as the hooks beside it: /usr/bin/perl with core
# JSON::PP starts in ~60ms where /usr/bin/python3 costs ~1.5s, and this runs
# on every Bash tool call. Run --self-test after editing.

use strict;
use warnings;
use JSON::PP ();

my $HEREDOC = qr/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/;

# A whole word of two or more equals signs. One `=` is excluded: it has no
# command name following it, so zsh leaves it alone and `[ x = x ]` works.
my $BARE_EQUALS = qr/(?:^|(?<=[\s;|&(]))(={2,})(?=[\s;|&)]|$)/;

# Byte offsets sitting inside a quoted string. Only the start of a candidate
# word is tested, so marking the quote characters themselves costs nothing.
sub quoted_offsets {
    my ($line) = @_;
    my ( @inside, $single, $double );

    for ( my $i = 0; $i < length $line; $i++ ) {
        my $char = substr $line, $i, 1;

        if ( $char eq '\\' && !$single ) {
            $inside[$i] = $inside[ $i + 1 ] = ( $single || $double ) ? 1 : 0;
            $i++;
            next;
        }
        if ( $char eq q{'} && !$double ) { $single = !$single; $inside[$i] = 1; next }
        if ( $char eq q{"} && !$single ) { $double = !$double; $inside[$i] = 1; next }

        $inside[$i] = ( $single || $double ) ? 1 : 0;
    }

    return \@inside;
}

# Byte offsets inside `[[ ... ]]` or `(( ... ))`, where `==` is an operator
# rather than a word and quoting it changes the meaning. Openers and closers
# found inside quotes are ignored, so an echoed "[[" does not open a region.
sub construct_offsets {
    my ( $line, $quoted ) = @_;
    my @inside = (0) x length $line;
    my $depth  = 0;

    for ( my $i = 0; $i < length($line) - 1; $i++ ) {
        my $pair = substr $line, $i, 2;
        next if $quoted->[$i];

        if ( $pair eq '[[' || $pair eq '((' ) {
            $depth++;
            $i++;
        }
        elsif ( ( $pair eq ']]' || $pair eq '))' ) && $depth ) {
            $depth--;
            $i++;
        }
        elsif ($depth) {
            $inside[$i] = 1;
        }
    }
    $inside[ length($line) - 1 ] = 1 if $depth && length $line;

    return \@inside;
}

# Quote every bare equals run that is really a shell word. Returns the new
# command, or undef when nothing changed.
sub rewrite {
    my ($command) = @_;
    my ( @out, $changed, $terminator );

    for my $line ( split /\n/, $command, -1 ) {

        if ( defined $terminator ) {
            push @out, $line;
            undef $terminator if $line =~ /^\s*\Q$terminator\E\s*$/;
            next;
        }

        my $rewritten = $line;
        my $from      = 0;

        while (1) {
            pos($rewritten) = $from;
            last unless $rewritten =~ /$BARE_EQUALS/g;

            my ( $start, $end, $run ) = ( $-[1], $+[1], $1 );
            my $quoted = quoted_offsets($rewritten);

            if ( $quoted->[$start] || construct_offsets( $rewritten, $quoted )->[$start] ) {
                $from = $start + length $run;
                next;
            }

            substr( $rewritten, $start, $end - $start ) = "'$run'";
            $changed++;
            $from = $start + length($run) + 2;
        }

        push @out, $rewritten;
        $terminator = $2 if $line =~ $HEREDOC;
    }

    return $changed ? join( "\n", @out ) : undef;
}

sub run_hook {
    my $raw = do { local $/; <STDIN> };
    return unless defined $raw && length $raw;
    my $payload = JSON::PP->new->decode($raw);
    return unless ( $payload->{tool_name} // '' ) eq 'Bash';

    my $input = $payload->{tool_input};
    return unless ref $input eq 'HASH' && defined $input->{command};

    my $rewritten = rewrite( $input->{command} );
    return unless defined $rewritten;

    my %updated = ( %$input, command => $rewritten );

    print JSON::PP->new->canonical->encode(
        {   hookSpecificOutput => {
                hookEventName => 'PreToolUse',
                updatedInput  => \%updated,
            }
        }
    ), "\n";
    return;
}

sub load_cases {
    my ( @rewrite, @keep );
    my $bucket;
    while ( my $line = <DATA> ) {
        chomp $line;
        next if $line =~ /^\s*$/ || $line =~ /^#/;
        if    ( $line eq '[rewrite]' ) { $bucket = \@rewrite; next }
        elsif ( $line eq '[keep]' )    { $bucket = \@keep;    next }
        $line =~ s/\\n/\n/g;
        push @$bucket, $line;
    }
    return ( \@rewrite, \@keep );
}

sub self_test {
    my ( $rewrite, $keep ) = load_cases();
    my $failed = 0;

    for my $case (@$rewrite) {
        my ( $before, $after ) = split / => /, $case, 2;
        my $got = rewrite($before);
        if ( !defined $got ) {
            print "FAIL (no rewrite): $before\n";
            $failed++;
        }
        elsif ( $got ne $after ) {
            print "FAIL: $before\n  want: $after\n  got:  $got\n";
            $failed++;
        }
    }

    for my $case (@$keep) {
        my $got = rewrite($case);
        if ( defined $got ) {
            print "FAIL (rewrote a keep case): $case\n  got: $got\n";
            $failed++;
        }
    }

    my $total = @$rewrite + @$keep;
    print $failed ? "$failed of $total failed\n" : "all $total cases pass\n";
    return $failed ? 1 : 0;
}

exit self_test() if @ARGV && $ARGV[0] eq '--self-test';
run_hook();

__DATA__

[rewrite]
# The separator that produced the 87 hits.
echo === => echo '==='
echo ==== => echo '===='
echo ===== => echo '====='

# Mid-pipeline, where the abort silently drops everything after it.
sed -n '5,40p' a.md; echo ===; sed -n '655,680p' b.md => sed -n '5,40p' a.md; echo '==='; sed -n '655,680p' b.md

# Several on one line, each quoted independently.
echo ===; ls; echo ====; pwd => echo '==='; ls; echo '===='; pwd

# Not echo-specific: any command aborts the same way.
printf %s === => printf %s '==='
grep === /etc/hosts => grep '===' /etc/hosts

# Single-bracket test really does fail unquoted, and quoting repairs it.
[ x == x ] && echo yes => [ x '==' x ] && echo yes

# Inside a command substitution the shell aborts just the same.
out=$(echo === ) => out=$(echo '===' )

# After a pipe and after &&.
ls | grep === => ls | grep '==='
true && echo === => true && echo '==='

# Code before a heredoc is still code.
echo ===\ncat <<'EOF' > f\nbody\nEOF => echo '==='\ncat <<'EOF' > f\nbody\nEOF

[keep]
# Already quoted, either way.
echo '==='
echo "==="
echo "=== quoted ==="

# A lone `=` never expands: nothing follows it to name a command.
echo =
[ x = x ]

# Expansion only applies at the start of a word.
echo a===b
echo --flag===x
curl -H 'Accept: application/json' --data foo===bar

# `[[ ]]` uses == as an operator; quoting it breaks the condition.
if [[ $a == $b ]]; then echo same; fi
[[ "$x" == "y" ]] && echo hit
while [[ $n == 0 ]]; do break; done

# `(( ))` is arithmetic, not word expansion.
if (( 1 == 1 )); then echo ok; fi
(( count == 0 )) && echo none

# A deliberate `=cmd` expansion is a real zsh feature, not a typo.
echo =ls

# Inside a heredoc body the text is data being written to a file.
cat <<'EOF' > note.md\n=== heading ===\nEOF

# Quoted as data rather than run.
python3 -c "print('===')"
echo "run: echo === here"
