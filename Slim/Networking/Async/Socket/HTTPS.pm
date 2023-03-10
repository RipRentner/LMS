package Slim::Networking::Async::Socket::HTTPS;

# $Id$

# Copyright 2003-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

BEGIN {
	# Force Net::HTTPS to use IO::Socket::SSL
	use IO::Socket::SSL;
	
	# Latest IO::Socket::SSL (2.002) update changes defaults to be more restrictive.
	# Unfortunately the hostname check fails most SSL protecte web sites...
	if (main::SLIM_SERVICE) {
		IO::Socket::SSL::set_defaults(
			SSL_verify_mode => SSL_VERIFY_NONE
		);
	}
}

use base qw(Net::HTTPS Slim::Networking::Async::Socket);

sub close {
	my $self = shift;

	# remove self from select loop
	Slim::Networking::Select::removeError($self);
	Slim::Networking::Select::removeRead($self);
	Slim::Networking::Select::removeWrite($self);
	Slim::Networking::Select::removeWriteNoBlockQ($self);

	$self->SUPER::close();
}

1;