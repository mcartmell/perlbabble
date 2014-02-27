#!/usr/bin/perl -wT
require 5.002;
use strict;
use IO::Socket;
use IO::Select;

my $port = scalar(@ARGV)>0 ? $ARGV[0] : 2323;

$| = 1;
my $listen = IO::Socket::INET->new(Proto => 'tcp',
           LocalPort => $port,
           Listen => 1,
           Reuse => 1) or die $!;
print "PerlBabble started on port $port\n";

my $select = IO::Select->new($listen);
my @users;

# the main data hash
my $game = {};
$game->{status} = "waiting";
$game->{users} = \&handles;

# Configuration options here
$game->{win_score} = 10;
$game->{min_players} = 3;
$game->{num_adjectives} = 15;
$game->{num_nouns} = 15;
$game->{num_verbs} = 15;
$game->{num_punctuation} = 5;
$game->{num_prepositions} = 10;
$game->{num_pronouns} = 10;
$game->{wait_startgame} = 15;
$game->{wait_startround} = 10;
$game->{wait_sentence} = 30;
$game->{wait_voting} = 20;
$game->{wait_results} = 5;
$game->{wait_endgame} = 5;

# comment out this line on win32
$SIG{'PIPE'} = 'IGNORE';
$SIG{ALRM} = \&heartbeat;

my @ready;
while (1) {
    while(@ready = $select->can_read) {
        print "going: ".join(', ',map {$_->fileno} @ready) . "\n";
        my $socket;
        foreach $socket (@ready) {
          if($socket == $listen) {
              my $new_socket = $listen->accept;
              PerlBabble::User->new($new_socket, $select, \@users, $game);
          } else {
              my $user = $users[$socket->fileno];
              if(defined $user) {
                &{$user->nextsub}();
              } else {
                print "unknown user\n";
              }
          }
        }
    }
}

sub heartbeat {

    my @handles = &handles;
    if ($game->{status} eq "waiting") {
        if (scalar(@handles) >= $game->{min_players}) {
            # we have more enough users to start, let's play!
            $game->{status} = "starting";
            &start_game;
            &broadcast("New game starting in $game->{wait_startgame} seconds...");
            alarm $game->{wait_startgame};
        }
    }
    else {
        if (scalar(@handles) < $game->{min_players}) {
            $game->{status} = "waiting";
            &broadcast("Not enough players, aborting...");
            &end_game;
        } else {
            if ($game->{status} eq "starting") {
                $game->{status} = "game";
                &start_round;
                alarm $game->{wait_sentence};
            }
            elsif ($game->{status} eq "game") {
                $game->{status} = "voting";
                &do_voting;
            }
            elsif ($game->{status} eq "voting") {
                $game->{status} = "results";
                &show_results;
                &finish_round;
                alarm $game->{wait_results};
            }
            elsif ($game->{status} eq "results") {
                if (&game_finished) {
                    &end_game;
                    $game->{status} = "finished";
                    alarm $game->{wait_endgame};
                } else {
                    $game->{status} = "starting";
                    &broadcast("Next round starting in $game->{wait_startround} seconds...");
                alarm $game->{wait_startround};
                }
            }
            elsif ($game->{status} eq "finished") {
                $game->{status} = "starting";
                &broadcast("Next game starting in $game->{wait_startgame} seconds...");
                alarm $game->{wait_startgame}
            }
        }
    }
}

sub game_finished {
    my (@winners, @realwinners);
    foreach my $socket ($select->handles) {
        my $user = $users[$socket->fileno];
        if ($user->{ready} && $user->{score} >= $game->{win_score}) {
            push @winners, $user;
        }
    }
    return unless (@winners);
    @winners = sort {$b->{score} <=> $a->{score}} @winners;
    push @realwinners, $winners[0]->{handle};
    my $winning_score = $winners[0]->{score};
    for my $i (1..$#winners) {
        last unless ($winners[$i]->{score} == $winning_score);
        push @realwinners, $winners[$i]->{handle};
    }
    if (scalar(@realwinners) == 1) {
        &broadcast ("Game over. $realwinners[0]->{handle} wins the game with $winning_score points!");
    } else {
        &broadcast ("Game over. The winners are: ".(join ", ", @realwinners)." with $winning_score points!");
    }
    return 1;
}


sub start_round {
    my @files = <themes/*>;
    my @dirs;
    my (@adjectives, @nouns, @verbs, @prepositions, @pronouns, @punctuation);
    srand;
    foreach my $item (@files) {
        push @dirs, $item if (-d $item);
    }
    my $theme = $dirs[rand(@dirs)];
    $theme =~s/themes\///;
    $game->{theme} = $theme;
    map {$game->{$_} = &get_words("themes/$theme/$_", $game->{"num_$_"});
    }qw(adjectives nouns verbs);
    map {$game->{$_} = &get_words("themes/$_", $game->{"num_$_"});
    }qw(prepositions pronouns punctuation);
    my ($code, $wordlist);
    map{$code .= '@'."$_".' = @{$game->{'."$_".'}};'}qw(adjectives nouns verbs prepositions pronouns punctuation);
    eval $code;
    while (@adjectives || @nouns || @verbs
          || @prepositions || @pronouns || @punctuation) {
        $wordlist.=
        sprintf("%-13s%-13s%-13s%-13s%-13s%-13s",
        (@adjectives ? pop(@adjectives) : ''),
        (@nouns ? pop(@nouns) : ''),
        (@verbs ? pop(@verbs) : ''),
        (@prepositions ? pop(@prepositions) : ''),
        (@pronouns ? pop(@pronouns) : ''),
        (@punctuation ? pop(@punctuation) : ''))
        ."\r\n";
    }
    &broadcast("The theme is \'$game->{theme}\'\r\nYou have $game->{wait_sentence} seconds to make a sentence from:\r\n$wordlist\r\nUse /s (list of words separated by spaces) to input sentence");
}

sub get_words {
    my ($file, $number) = @_;
    open(FILE, "< $file");
    my @words = <FILE>;
    my @chosen;
    for(1..$number){
        my $word = $words[rand(@words)];
        chop($word);
        push @chosen, $word;
    }
    close(FILE);
    \@chosen;
}

sub broadcast {
    my ($msg) = @_;
    foreach my $socket ($select->handles) {
      my $user = $users[$socket->fileno];
      $user->write("\r\n$msg\r\n"), $user->do_prompt if(defined $user->{handle} && $user->{ready});
    }
}

sub do_voting {
    my $x=0;
    foreach my $socket ($select->handles) {
        my $user = $users[$socket->fileno];
        $x++ if (defined $user->{sentence});
    }
    if ($x < 2) {
        &broadcast("Not enough sentences to vote!\r\nNext round starting in $game->{wait_startround} seconds...");
        $game->{status}="starting";
        alarm $game->{wait_startround};
        return;
    }
    foreach my $socket ($select->handles) {
      my $user = $users[$socket->fileno];
      $user->show_votes if(defined $user->{handle} && $user->{ready});
    }
    alarm $game->{wait_voting};
}

sub show_results {
    my @players;
    foreach my $socket ($select->handles) {
        my $user = $users[$socket->fileno];
        push @players, $user if (defined $user->{handle} && $user->{ready});
    }
    @players = sort {$b->{votes} <=> $a->{votes}} @players;
    my $score = "Results of voting:";
    my $i;
    foreach my $player (@players) {
        $score.="\r\n#".++$i." ($player->{votes} votes) - ".$player->{handle}." with \"$player->{sentence}\"" if ($player->{sentence}); 
    }
    &broadcast($score);
}

sub finish_round {
    my $didnt_vote;
    foreach my $socket ($select->handles) {
        my $user = $users[$socket->fileno];
        if (defined $user->{handle} && $user->{ready}) {
            if (defined $user->{voted}) {
                $user->{score} += $user->{votes};
            } else {
                $didnt_vote .= "$user->{handle} didn't vote and receives no points for this round\r\n";
            }
            $user->{sentence} = undef;
            $user->{votes} = 0;
            $user->{vote_ids} = [];
            $user->{voted} = undef;
        }
    }
    if ($didnt_vote) {
        $didnt_vote = substr($didnt_vote,0,-2);
        &broadcast($didnt_vote);
    }
}

sub start_game {
    foreach my $socket ($select->handles) {
        my $user = $users[$socket->fileno];
        $user->{ready} = 1 if (defined $user->{handle});
    }
}

sub end_game {
    foreach my $socket ($select->handles) {
        my $user = $users[$socket->fileno];
        $user->reset if (defined $user->{handle});
    }
}

sub handles {
    my @handles;
    foreach my $socket ($select->handles) {
        my $user = $users[$socket->fileno];
        push @handles, $user->{handle} if (defined $user->{handle});
    }
    return @handles;
}

package PerlBabble::User;
use strict;

sub new {
    my($class,$socket,$select,$users,$game) = @_;

    my $self = {
  'socket' => $socket,
  'select' => $select,
  'users' => $users,
    'game' => $game,
    'ready' => 0,
    'score' => 0,
    'votes' => 0
  };

    bless $self,$class;

    $users->[$socket->fileno] = $self;
    $self->select->add($socket);

    $self->log("connected");
    $self->ask_for_handle;

    return $self;
}

sub socket { $_[0]->{'socket'} }
sub select { $_[0]->{'select'} }
sub users { $_[0]->{'users'} }
sub game { $_[0]->{'game'} }
sub handle { $_[0]->{'handle'} }
sub nextsub { $_[0]->{'nextsub'} }
sub ready { $_[0]->{'ready'} }

sub reset {
    my ($self) = @_;
    $self->{vote_ids} = [];
    $self->{score} = 0;
    $self->{votes} = 0;
    $self->{voted} = undef;
    $self->{ready} = 0;
    $self->{sentence} = undef;
}

sub ask_for_handle {
    my($self) = @_;
    my $welcome = "Welcome to PerlBabble!\r\n";
    $welcome =~ s:\n:\r\n:g;
    $self->write($welcome);
    $self->write("choose a name: ");
    $self->{'nextsub'} = sub { $self->get_handle };
}

sub get_handle {
    my($self) = @_;

    my $handle = $self->read or return;
    $handle =~ tr/ -~//cd;
    $self->{'handle'} = $handle;
    $self->broadcast("*** $handle joins the game");
    $self->log("handle: $handle");
    $self->{'nextsub'} = sub { $self->input };
    $self->write("\r\nWaiting until next round\r\n") if ($self->{game}->{status} ne "waiting");
    $self->do_prompt;
    my @handles = $self->{game}->{users}->();
    alarm 1 if (scalar(@handles) >= 2 && $game->{status} eq "waiting")
}

sub input {
    my($self) = @_;
    my $line = $self->read;
    return if($line eq "");
    $line =~ tr/ -~//cd;
    my $handle = $self->handle;

    # get input
    if ($line =~ /^\/say\s+(\S+.*)/){
        $self->broadcast("<$handle> $1");
    }

    elsif ($line =~ /^\/s(en)?\s/) {
        if ($self->{game}->{status} eq "game") {
            if ($line =~ /^\/s(en)?\s(\S+.*)/) {
                $self->check_sentence(split /\s/,$2);
            } else {
                $self->write((($self->{sentence}) ? "Current sentence: $self->{sentence}" : "No sentence yet")."\r\n");
            }
        }
    }

    elsif ($line =~ /^\/vote\s#?(\d+)/) {
        if ($self->{game}->{status} eq "voting") {
            $self->give_vote($1);
        }
    }

    elsif ($line =~ /^\/scores?/) {
        $self->show_scores unless ($self->{game}->{status} eq "waiting");
    }

    else {
        $self->broadcast("<$handle> $line");
    }

    $self->do_prompt; # always?

}

sub broadcast {
    my($self,$msg) = @_;
    my $socket;
    foreach $socket ($self->select->handles) {
      my $user = $self->users->[$socket->fileno];
      $user->write("\r\n$msg\r\n"), $user->do_prompt if(defined $user->{handle} && $user->{handle} ne $self->{handle});
    }
    $self->write("$msg\r\n");
}

sub read {
    my($self) = @_;

    my $buf="";
    $self->socket->recv($buf,80);
    $self->leave if($buf eq "");
    return $buf;
}

sub write {
    my($self,$buf) = @_;
    $self->socket->send($buf) or $self->leave;
}

sub do_prompt {
    my($self) = @_;
    $self->socket->send('> ');
}

sub leave {
    my($self) = @_;
    my $x;

    print "leave called\n";
    $self->{ready} = 0;

    foreach my $socket ($self->select->handles) {
        my $user = $self->users->[$socket->fileno];
        $x++ if ($user->{ready});
    }
    alarm 1 if ($x < $self->{game}->{min_players} && $game->{status} ne "waiting");
    $self->users->[$self->socket->fileno] = undef;
    $self->select->remove($self->socket);
    my $handle = $self->handle;
    $self->broadcast("*** $handle leaves") if(defined $handle);
    $self->log("disconnected");
    $self->socket->close;
}

sub log {
    my($self,$msg) = @_;
    my $fileno = $self->socket->fileno;
    print "$fileno: $msg\n";
}

sub check_sentence {
    my ($self, @words) = @_;
    my @wordlist;
    my @sentence = @words;
    map{
        push @wordlist, @{$self->game->{$_}};
    }qw(adjectives verbs nouns pronouns prepositions punctuation);
    OUTER: while (@words) {
        my $word = pop(@words);
        for my $i (0..$#wordlist) {
            if ($word eq $wordlist[$i]) {
                $wordlist[$i] = '';
                next OUTER;
            }
        }
        $self->write("Invalid sentence\r\n");
        return;
    }
    my $sentence = join(" ", @sentence);
    $sentence =~ s/\s\+//;
    $sentence =~ s/\s(\!|\?|\.|\,)/$1/;
    $self->write("Your sentence is: " . $sentence . "\r\n");
    $self->{sentence} = $sentence;
}    

sub shuffle {
    my $array = shift;
    my $i;
    for ($i = @$array; --$i; ) {
        my $j = int rand ($i+1);
        next if $i == $j;
        @$array[$i,$j] = @$array[$j,$i];
    }
}

sub give_vote {
    my($self,$vote) = @_;
    $self->write("Already voted this round\r\n"), return if defined($self->{voted});
    chomp($vote);
    $vote--;
    $self->write("Invalid vote\r\n"), return unless defined($self->{vote_ids}->[$vote]);
    $self->write("Can't vote for self!\r\n"), return if ($self->{vote_ids}->[$vote] eq $self);
    $self->{vote_ids}->[$vote]->{votes}++;
    $self->{voted} = $self->{vote_ids}->[$vote];
    $self->write("Vote recorded\r\n");
}

sub show_votes {
    my($self,$msg) = @_;
    my ($socket,$i);
    my @handles = $self->select->handles;
    &shuffle(\@handles);
    while (@handles) {
        my $sock = pop(@handles);
        my $user = $self->users->[$sock->fileno];
        push @{$self->{vote_ids}}, $user if ($user->{sentence});
    }
    $self->write("\r\nSentences - /vote for your favourite!:\r\n\r\n");
    foreach my $user (@{$self->{vote_ids}}) {
        $self->write("#".++$i." - \"$user->{sentence}\"\r\n");
    }
    $self->do_prompt;
}

sub show_scores {
    my ($self) = @_;
    my @players;
    foreach my $socket ($self->select->handles) {
        my $user = $self->users->[$socket->fileno];
        push @players, $user if (defined $user->{handle} && $user->{ready});
    }
    @players = sort {$b->{score} <=> $a->{score}} @players;
    my $score = "Scores:\r\n";
    my $i=0;
    foreach my $player (@players) {
        $score .= "#".++$i." $player->{handle} - $player->{score}\r\n";
    }
    $self->write($score);
}
