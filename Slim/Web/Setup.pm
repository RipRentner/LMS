package Slim::Web::Setup;

# $Id$

# Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use Slim::Utils::Log;

sub initSetup {
	my @classes = ('Slim::Web::Settings');
	
	push @classes, map { 
		join('::', qw(Slim Web Settings Player), $_) 
	} qw(
		Alarm 
		Audio 
		Basic 
		Display 
		Menu 
		Remote 
		Synchronization
	) if main::LOCAL_PLAYERS;
	
	push @classes, map { 
		join('::', qw(Slim Web Settings Server), $_) 
	} qw(
		Basic 
		Behavior 
		Debugging 
		FileSelector 
		Index 
		Network 
		Performance 
		Security 
		Software 
		Status 
		TextFormatting 
		Wizard
	);

	push @classes, map { 
		join('::', qw(Slim Web Settings Server), $_) 
	} qw(
		SqueezeNetwork 
		UserInterface 
	) if main::LOCAL_PLAYERS;
	
	if (main::THIRDPARTY) {
		push @classes, 'Slim::Web::Settings::Server::Plugins';
	}

	if (main::TRANSCODING) {
		push @classes, 'Slim::Web::Settings::Server::FileTypes';
	}

	for my $class (@classes) {
		eval "use $class";

		if (!$@) {

			$class->new;

		} else {

			logError ("can't load $class - $@");
		}
	}

}

1;

__END__
