#!/usr/bin/env perl
use utf8;
use strict;
use warnings;
use open IO => ':encoding(UTF-8)';
use v5.26;

use feature 'signatures';
no warnings 'experimental::signatures';

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Util qw(fork_call);
use AnyEvent::I3 qw(TYPE_GET_WORKSPACES TYPE_COMMAND);
use Storable qw(dclone);
use IPC::Open3;
use JSON::XS qw(encode_json);
#use Carp::Always;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;



#use IO::File;
#my $output = IO::File->new("/tmp/logger", O_WRONLY | O_CREAT | O_TRUNC);
#$output->autoflush(1);

#BEGIN {
#close STDERR;
#open(STDERR, '>', "/tmp/monout") or exit 37;
#STDERR->autoflush(1);
#}


$| = 1;

my %commands = (
	"nop workspace-switcher-right" => \&workspace_right,
	"nop workspace-switcher-left" => \&workspace_left,
	"nop workspace-switcher-swap" => \&workspace_swap,
);

my ($stdin, $statusbar);

my $evt_loop = AnyEvent->condvar;
my $SLOP_RESULT;
say STDOUT '{ "version": 1, "click_events": true }';
reconnect_i3(1);
reconnect_statusbar(1);
$evt_loop->recv;
exit 1;

sub reconnect_i3($immediate = undef) {
	my $resolver = AnyEvent->condvar;
	my $i3 = AnyEvent::I3->new();

	$resolver->cb(sub ($i3) {
		reconnect_i3_bindings($i3);
		reconnect_stdin($i3);
	});

	state $timeout;
	$timeout = AnyEvent->timer(
		after => 3,
		cb => sub {
			die "Connection to i3 timed out. Verify socket path ($i3->{path}).";
			exit 1;
		}
	) unless defined $timeout;

	my $delay; $delay = AnyEvent->timer(
		after => 0.1,
		cb => my $connect = sub { 
			undef $delay;

			$i3->connect->cb(sub ($status) { 
				return reconnect() unless $status->recv;
				undef $timeout;
				$resolver->send($i3);
			});
		}
	);

	$connect->() if $immediate;

	return $resolver;
}

sub reconnect_statusbar {
	my $conf = "~/.i3/i3status.conf";
	$conf = "/etc/i3/i3status.conf" unless -e $conf;

	my $pid = open3(my $in, my $out, my $err, 'i3status', '-c', $conf)
		or die "Unable to exec i3status: $!";

	my $hdl = $statusbar = AnyEvent::Handle->new(
		fh => $out,
		on_error => sub ($hdl, $fatal, $msg) {
			AE::log error => "Statusbar: $msg";
			$hdl->destroy;
			$evt_loop->send;
		}
	);

	# Skip version information, maybe validate it in the future?
	$hdl->push_read(json => sub {});

	$hdl->on_read(sub ($hdl) {
		# i3status returns an endless list. Strip off the opening [ and
		# the intermittant , separators. If the regex doesn't match, wait
		# for more data to accumulate.
		return unless $hdl->rbuf =~ s/^\s*([\[,]\s*)\[/[/;
		my $separator = $1;

		$hdl->push_read(json => sub ($hdl, $blocks) { handle_statusbar($separator, $blocks) });
	});
}

sub reconnect_stdin($i3) {
	my $hdl = $stdin = AnyEvent::Handle->new(
		fh => \*STDIN,
		on_error => sub  ($hdl, $fatal, $msg) {
			AE::log error => "stdin: $msg";
			$hdl->destroy;
			$evt_loop->send;
		}
	);

	$hdl->on_read(sub ($hdl) {
		return unless $hdl->rbuf =~ s/^\s*([\[,]\s*)\{/{/;
		$hdl->push_read(json => sub ($hdl, $event) { handle_click_event($i3, $event) });
	});
}

sub handle_click_event($i3, $event) {
	if($event->{name} eq "slop") {
		if($event->{button} == 3) {
			$SLOP_RESULT = undef;
			handle_statusbar();
			return
		}
		elsif($event->{button} == 1) {
			calculate_slop();
			return;
		}
	}

	return unless $event->{button} == 4 or $event->{button} == 5;

	$i3->recv->get_workspaces()->cb(sub ($cv) {
		my $workspaces = $cv->recv;
		my @filter;
		my $visible;

		foreach(@$workspaces) {
			my $relx = $event->{x} - $_->{rect}{x};
			my $rely = $event->{y} - $_->{rect}{y};

			next unless $relx >= 0 and $relx < $_->{rect}{width};
			next unless $rely >= 0 and $rely < ($_->{rect}{height} + 60); # 60 comes from the height of i3bar
		
			$visible = $_ if $_->{visible};
			$_->{index} = -1 + push(@filter, $_);
		}

		return unless defined $visible;

		my $target;
		if($event->{button} == 4 and $visible->{index} != 0) {
			$target = $filter[$visible->{index} - 1];
		}
		elsif($event->{button} == 5) {
			$target = $filter[$visible->{index} + 1];
		}

		if(defined $target and ($target != $visible)) {
			if($target->{num} >= 0) {
				$i3->recv->command(qq{workspace number $target->{num}});
			}
			else {
				my $safename = quotemeta($target->{name});
				$i3->recv->command(qq{workspace "$safename"});
			}
		}
	});
}


my $cache;
sub handle_statusbar($separator = ",", $blocks = $cache) {
	return unless defined $blocks;
	$cache = $blocks;
	$blocks = dclone($blocks);
	unshift @$blocks, block_ram_available();
	unshift @$blocks, block_slop();
	say STDOUT $separator . encode_json($blocks);
}

sub block_ram_available {
	open my $FH, '<', '/proc/meminfo' or die $!;
	my $mem_available = 'unknown';
	while(my $line = <$FH>) {
		if($line =~ /MemAvailable:\s*(\d+)/) {
			$mem_available = $1;
			last;
		}
	}
	close $FH;
	return {
		full_text => "Availableh: " . POSIX::round($mem_available / 1024) . " MiB",
		name => 'ram_available'
	};
}

sub block_slop {
	return {
		full_text => $SLOP_RESULT // "slop",
		name => "slop"
	};
}


sub reconnect_i3_bindings($i3) {
	$i3->recv->subscribe({
		binding => sub ($event) {

			my $command = $commands{$event->{binding}{command}};
			$command->($i3->recv) if(defined $command);
		},
		_error => \&reconnect_i3
	});
}

# Offset indicated the direction of iterator. 
# 0 indicates left to right; -1 indicates right to left.
sub find_adjacent_workspace($offset, $workspaces, $create) {
	my $focused_output;
	my $max = 0;

	# Walk through the workspaces until we find the currently focused
	# workspace.
	while($workspaces->$#* >= 0 and my $workspace = splice @$workspaces, $offset, 1) {
		$max = $workspace->{num} if $workspace->{num} > $max;

		if($workspace->{focused}) {
			$focused_output = $workspace->{output};
			last;
		}
	}

	# Continue until we encounter another workspace on the same output as the
	# focused workspace.
	while($workspaces->$#* >= 0 and my $workspace = splice @$workspaces, $offset, 1) {
		$max = $workspace->{num} if $workspace->{num} > $max;

		# When found, we return that workspace's number
		return $workspace
			if($workspace->{output} eq $focused_output);
	}


	# If there's no following workspace and we can create new workspaces,
	# we create a new workspace.
	return $create ? { num => $max + 1, name => "" . ($max + 1) } : undef;
}


sub workspace_right($i3) {
	$i3->get_workspaces->cb(sub ($cv) {
		my $target = find_adjacent_workspace(0, $cv->recv, 1);
		return if(not defined $target);
		if($target->{num} >= 0) {
			$i3->command(qq{workspace number $target->{num}});
		}
		else {
			my $safename = quotemeta($target->{name});
			$i3->command(qq{workspace "$safename"});
		}
	});
}

sub workspace_left($i3) {
	$i3->get_workspaces->cb(sub ($cv) {
		my $target = find_adjacent_workspace(-1, $cv->recv, 0);
		return if(not defined $target);
		if($target->{num} >= 0) {
			$i3->command(qq{workspace number $target->{num}});
		}
		else {
			my $safename = quotemeta($target->{name});
			$i3->command(qq{workspace "$safename"});
		}
	});
}

sub workspace_swap($i3) {
	$i3->get_workspaces->cb(sub ($cv) {
		foreach(sort {$a->{focused} <=> $b->{focused}} grep {$_->{visible}} $cv->recv->@*) {
			if($_->{num} >= 0) {
				$i3->command(qq{workspace number $_->{num}, move workspace to output right});
			}
			else {
				my $safename = quotemeta($_->{name});
				$i3->command(qq{workspace "$safename", move workspace to output right});
			}
		}
	});
}


sub calculate_slop($i3 = undef) {
	fork_call {
		return qx"slop";
	} sub($dimensions = undef) {
		chomp $dimensions if($dimensions);
		$SLOP_RESULT = $dimensions // $SLOP_RESULT;
		handle_statusbar();
	};
}
