package Slim::GUI::ControlPanel::Diagnostics;

# Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use base 'Wx::Panel';

use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON);

use Net::Ping;
use Socket;
use Symbol;

use Slim::Utils::Light;
use Slim::Utils::ServiceManager;

my $svcMgr = Slim::Utils::ServiceManager->new();

use constant SN   => 'www.mysqueezebox.com';
use constant UESR => 'www.uesmartradio.com';

my @checks;
my $cache;
my $alertBox;

sub new {
	my ($self, $nb) = @_;

	$self = $self->SUPER::new($nb);

	my $mainSizer = Wx::BoxSizer->new(wxVERTICAL);

	$alertBox = Wx::TextCtrl->new($self, -1, '', [-1, -1], [-1, 90], wxTE_MULTILINE | wxTE_READONLY | wxTE_RICH | wxTE_RICH2 | wxTE_AUTO_URL);

	my $scBoxSizer = Wx::StaticBoxSizer->new( 
		Wx::StaticBox->new($self, -1, string('SQUEEZEBOX_SERVER')),
		wxVERTICAL
	);
	my $scSizer = Wx::FlexGridSizer->new(0, 2, 5, 10);
	$scSizer->AddGrowableCol(0, 2);
	$scSizer->AddGrowableCol(1, 1);
	$scSizer->SetFlexibleDirection(wxHORIZONTAL);

	$self->_addItem($scSizer, string('SQUEEZEBOX_SERVER') . string('COLON'), sub {
		$_[0] ? string('RUNNING') : string('STOPPED');
	});
	$self->_addItem($scSizer, string('INFORMATION_SERVER_IP') . string('COLON'), \&getHostIP);
	
	if (main::LOCAL_PLAYERS) {
		$self->_addItem($scSizer, string('CONTROLPANEL_PORTNO', '', main::SLIMPROTO_PORT, 'slimproto'), sub {
			checkPort(getHostIP(), main::SLIMPROTO_PORT, $_[0]);
		});
	}
	
	my $httpPort = Slim::GUI::ControlPanel->getPref('httpport') || main::WEB_PORT;
	$self->_addItem($scSizer, string('CONTROLPANEL_PORTNO', '', $httpPort, 'HTTP'), sub {
		my $isRunning = shift;
		my ($state, $stateString) = checkPort(getHostIP(), $httpPort, 1);

		# check failed - let's try to figure out why
		if ($isRunning && !$state) {
			$alertBox->AppendText(string('CONTROLPANEL_PORTBLOCKED', '', $httpPort));
			
			# server running, but not accessible -> firewall?
			if (main::ISWINDOWS && (my $conflicts = $self->getConflictingApp('Firewall'))) {
				$alertBox->AppendText(string('CONTROLPANEL_PORTBLOCKED_APPS'));
				
				foreach (keys %$conflicts) {
					my $conflict = $conflicts->{$_};

					$alertBox->AppendText("\n* " . ($conflict->{ProgramName} || $conflict->{ProgramName}));
					$alertBox->AppendText(string('COLON') . ' ' . string('CONTROLPANEL_CONFLICT_' . uc($conflict->{Help}))) if $conflict->{Help};
				}
				
				$alertBox->AppendText("\n\n");
			}
		}
		
		elsif (!$isRunning && $state) {
			$alertBox->AppendText(string('CONTROLPANEL_PORTCONFLICT', '', $httpPort));

			# server not running, but port open -> other application using it?
			if (main::ISWINDOWS && (my $conflicts = $self->getConflictingApp('PortConflict'))) {
				
				foreach (keys %$conflicts) {
					my $conflict = $conflicts->{$_};

					if ($conflict->{Port} == $httpPort || $conflict->{ServiceName} eq 'Perl') {
						$alertBox->AppendText("\n* " . ($conflict->{ProgramName} || $conflict->{ProgramName}));
						$alertBox->AppendText(string('COLON') . ' ' . string('CONTROLPANEL_CONFLICT_' . uc($conflict->{Help}))) if $conflict->{Help};
					}
				}
				
				$alertBox->AppendText("\n\n");
			}

		}
		
		# on Windows we want to look out for other potential offenders...
		elsif (main::ISWINDOWS && !$isRunning && (my $conflicts = $self->getConflictingApp('Other'))) {
			$alertBox->AppendText(string('CONTROLPANEL_OTHER_ISSUE'));
				
			foreach (keys %$conflicts) {
				my $conflict = $conflicts->{$_};

				$alertBox->AppendText("\n* " . ($conflict->{ProgramName} || $conflict->{ProgramName}));
				$alertBox->AppendText(string('COLON') . ' ' . string('CONTROLPANEL_OTHER_ISSUE_' . uc($conflict->{Help}))) if $conflict->{Help};
			}
				
			$alertBox->AppendText("\n\n");
			
		}
				
		return $stateString;
	});

	if (main::LOCAL_PLAYERS) {
		my $cliPort = Slim::GUI::ControlPanel->getPref('cliport', 'cli.prefs') || 9090;
		$self->_addItem($scSizer, string('CONTROLPANEL_PORTNO', '', $cliPort, 'CLI'), sub {
			checkPort(getHostIP(), $cliPort, $_[0]);
		});
	}
	
	$scBoxSizer->Add($scSizer, 0, wxALL | wxGROW, 10);
	$mainSizer->Add($scBoxSizer, 0, wxALL | wxGROW, 10);


	my $uesrBoxSizer = Wx::StaticBoxSizer->new( 
		Wx::StaticBox->new($self, -1, string('UESMARTRADIO')),
		wxVERTICAL
	);
	my $uesrSizer = Wx::FlexGridSizer->new(0, 2, 5, 10);
	$uesrSizer->AddGrowableCol(0, 2);
	$uesrSizer->AddGrowableCol(1, 1);
	$uesrSizer->SetFlexibleDirection(wxHORIZONTAL);

	$self->_addItem($uesrSizer, string('INFORMATION_SERVER_IP') . string('COLON'), \&getUESRAddress);

	# check port 80 on squeezenetwork, as echo isn't available
	my ($uesrPing, $uesrPort);
	$self->_addItem($uesrSizer, string('CONTROLPANEL_PING'), sub {
		my $state;
		($uesrPing, $state) = checkPing(UESR, 80, 1);
		return $state;
	});
	
	$self->_addItem($uesrSizer, string('CONTROLPANEL_PORTNO', '', '3483', 'slimproto'), sub {
		my $state;

		if (Slim::GUI::ControlPanel->getPref('webproxy')) {
			$alertBox->AppendText(string('CONTROLPANEL_UESR_PROXY') . "\n\n");
			$state = string('CONTROLPANEL_FAILED');
		}
		
		else {
			($uesrPort, $state) = checkPort(getUESRAddress(), '3483', 1);
		}

		return $state;
	});
	
	$self->_addItem($uesrSizer, string('CONTROLPANEL_PORTNO', '', '9000', 'HTTP'), sub {
		my $proxy = Slim::GUI::ControlPanel->getPref('webproxy');

		# only do the more expensive http request if using a proxy
		if ($proxy) {
			require LWP::UserAgent;

			my $ua = LWP::UserAgent->new( timeout => 3 );
			$ua->proxy('http', "http://$proxy");

			my $result  = $ua->get('http://' . getUESRAddress() . ':9000');

			return string( $result->is_success ? 'CONTROLPANEL_OK' : 'CONTROLPANEL_FAILED' );
		}

		else {
			return checkPort(getUESRAddress(), '9000', 1);
		}
	});
	
	push @checks, {
		cb => sub {
			if (!$uesrPing || !$uesrPort) {
				$alertBox->AppendText(string('CONTROLPANEL_UESR_FAILURE'));
				$alertBox->AppendText("\n");
				$alertBox->AppendText(string('CONTROLPANEL_SN_FAILURE_DESC'));
				$alertBox->AppendText("\n\n");
			}
		},
	};
	
	$uesrBoxSizer->Add($uesrSizer, 0, wxALL | wxGROW, 10);
	$mainSizer->Add($uesrBoxSizer, 0, wxALL | wxGROW, 10);


	if (main::LOCAL_PLAYERS) {
		my $snBoxSizer = Wx::StaticBoxSizer->new( 
			Wx::StaticBox->new($self, -1, string('SQUEEZENETWORK')),
			wxVERTICAL
		);
		my $snSizer = Wx::FlexGridSizer->new(0, 2, 5, 10);
		$snSizer->AddGrowableCol(0, 2);
		$snSizer->AddGrowableCol(1, 1);
		$snSizer->SetFlexibleDirection(wxHORIZONTAL);
	
		$self->_addItem($snSizer, string('INFORMATION_SERVER_IP') . string('COLON'), \&getSNAddress);
	
		# check port 80 on squeezenetwork, as echo isn't available
		my ($snPing, $snPort);
		$self->_addItem($snSizer, string('CONTROLPANEL_PING'), sub {
			my $state;
			($snPing, $state) = checkPing(SN, 80, 1);
			return $state;
		});
		
		$self->_addItem($snSizer, string('CONTROLPANEL_PORTNO', '', '3483', 'slimproto'), sub {
			my $state;
	
			if (Slim::GUI::ControlPanel->getPref('webproxy')) {
				$alertBox->AppendText(string('CONTROLPANEL_SN_PROXY') . "\n\n");
				$state = string('CONTROLPANEL_FAILED');
			}
			
			else {
				($snPort, $state) = checkPort(getSNAddress(), '3483', 1);
			}
	
			return $state;
		});
		
		$self->_addItem($snSizer, string('CONTROLPANEL_PORTNO', '', '9000', 'HTTP'), sub {
			my $proxy = Slim::GUI::ControlPanel->getPref('webproxy');
	
			# only do the more expensive http request if using a proxy
			if ($proxy) {
				require LWP::UserAgent;
	
				my $ua = LWP::UserAgent->new( timeout => 3 );
				$ua->proxy('http', "http://$proxy");
	
				my $result  = $ua->get('http://' . getSNAddress() . ':9000');
	
				return string( $result->is_success ? 'CONTROLPANEL_OK' : 'CONTROLPANEL_FAILED' );
			}
	
			else {
				return checkPort(getSNAddress(), '9000', 1);
			}
		});
		
		push @checks, {
			cb => sub {
				if (!$snPing || !$snPort) {
					$alertBox->AppendText(string('CONTROLPANEL_SN_FAILURE'));
					$alertBox->AppendText("\n");
					$alertBox->AppendText(string('CONTROLPANEL_SN_FAILURE_DESC'));
					$alertBox->AppendText("\n\n");
				}
			},
		};
		
		$snBoxSizer->Add($snSizer, 0, wxALL | wxGROW, 10);
		$mainSizer->Add($snBoxSizer, 0, wxALL | wxGROW, 10);
	}


	my $alertBoxSizer = Wx::StaticBoxSizer->new( 
		Wx::StaticBox->new($self, -1, string('CONTROLPANEL_ALERTS')),
		wxVERTICAL
	);

	$alertBoxSizer->Add($alertBox, 0, wxALL | wxGROW, 10);

	$mainSizer->Add($alertBoxSizer, 0, wxALL | wxEXPAND, 10);


	my $btnRefresh = Wx::Button->new( $self, -1, string('CONTROLPANEL_REFRESH') );
	EVT_BUTTON( $self, $btnRefresh, sub {
		$self->_update();
	} );

	$mainSizer->Add($btnRefresh, 0, wxALL, 10);
		
	$self->SetSizer($mainSizer);

	return $self;
}

sub _addItem {
	my ($self, $sizer, $label, $checkCB) = @_;
	
	$sizer->Add(Wx::StaticText->new($self, -1, string($label)));
	
	my $labelText = Wx::StaticText->new($self, -1, '', [-1, -1], [-1, -1], wxALIGN_RIGHT);
	push @checks, {
		label => $labelText,
		cb    => ref $checkCB eq 'CODE' ? $checkCB : sub { $checkCB },
	};
	
	$sizer->Add($labelText);
}

sub _update {
	my ($self, $event) = @_;
	
	$alertBox->SetValue('');
	foreach my $check (@checks) {

		if ($check->{label}) {
			$check->{label}->SetLabel('');
			$self->Layout();
		}
	}

	$self->Update;

	my $isRunning = $svcMgr->checkServiceState() == SC_STATE_RUNNING;
	
	foreach my $check (@checks) {

		if (defined $check->{cb} && $check->{cb}) {
			eval {
				my $val = &{$check->{cb}}($isRunning);
				$check->{label}->SetLabel($val || 'n/a') if $check->{label};
				
				$self->Layout();
			};
			
			print "$@" if $@;
		}
	}
	
	$alertBox->ShowPosition(0);
	$self->Layout();
}

sub getConflictingApp {
	my ($self, $type) = @_;
	
	return unless main::ISWINDOWS;
	
	require XML::Simple;
	require Win32::Service;
	require Win32::Process::List;
	
	my $file = "../platforms/win32/installer/ApplicationData.xml";

	if (!-f $file && defined $PerlApp::VERSION) {
		$file = PerlApp::extract_bound_file('ApplicationData.xml');
	}

	return if !-f $file;
	
	my $ref = XML::Simple::XMLin($file);
	
	return unless $ref->{'d:Culture'}->{'d:process'};
	
	# create list of apps of the wanted type
	my (%apps, $conflicingApps);
	map { $apps{$_->{ServiceName}} = $_ }
	grep { $_->{type} eq $type }
	@{ $ref->{'d:Culture'}->{'d:process'} };

	foreach (keys %apps) {
		my %status;
		if (Win32::Service::GetStatus('.', $_, \%status)) {
			$conflicingApps->{$_} = $apps{$_};
		}
	}
	
	my $p = Win32::Process::List->new;
	if ($p->IsError != 1) {
		my %processes = $p->GetProcesses();
		
		foreach my $process ( grep { !$conflicingApps->{$_} } keys %apps ) {
			if (grep { $processes{$_} =~ /^$process\b/i } keys %processes) {
				$conflicingApps->{$process} = $apps{$process};
			}
		}
	}

	return $conflicingApps;
}

sub getHostIP {
	return $cache->{SC}->{IP} if $cache->{SC} && $cache->{SC}->{ttl} < time;

	# Thanks to trick from Bill Fenner, trying to use a UDP socket won't
	# send any packets out over the network, but will cause the routing
	# table to do a lookup, so we can find our address. Don't use a high
	# level abstraction like IO::Socket, as it dies when connect() fails.
	#
	# time.nist.gov - though it doesn't really matter.
	my $raddr = '192.43.244.18';
	my $rport = 123;

	my $proto = (getprotobyname('udp'))[2];
	my $pname = (getprotobynumber($proto))[0];
	my $sock  = Symbol::gensym();

	my $iaddr = inet_aton($raddr) || return;
	my $paddr = sockaddr_in($rport, $iaddr);
	socket($sock, PF_INET, SOCK_DGRAM, $proto) || return;
	connect($sock, $paddr) || return;

	# Find my half of the connection
	my ($port, $address) = sockaddr_in( (getsockname($sock))[0] );

	my $scAddress;
	$scAddress = inet_ntoa($address) if $address;

	$cache->{SC} = {
		ttl => time() + 60,
		IP  => $scAddress,
	} ;
	
	return $scAddress;
}

sub getSNAddress {
	return _getServerAddress(SN);
}

sub getUESRAddress {
	return _getServerAddress(UESR);
}

sub _getServerAddress {
	my $host = shift;
	
	return $cache->{$host}->{IP} if $cache->{$host} && $cache->{$host}->{ttl} < time;
	
	my @addrs = (gethostbyname($host))[4];
	
	my $address;
	$address = inet_ntoa($addrs[0]) if defined $addrs[0];

	$cache->{$host} = {
		ttl => time() + 60,
		IP  => $address,
	} ;
	
	return $address;
}

sub checkPort {
	my ($raddr, $rport, $serviceState) = @_;
	
	return (wantarray ? (0, string('CONTROLPANEL_FAILED')) : string('CONTROLPANEL_FAILED')) unless $raddr && $rport && $serviceState;

	my $iaddr = inet_aton($raddr);
	my $paddr = sockaddr_in($rport, $iaddr);

	socket(SSERVER, PF_INET, SOCK_STREAM, getprotobyname('tcp'));

	if (connect(SSERVER, $paddr)) {

		close(SSERVER);
		return wantarray ? (1, string('CONTROLPANEL_OK')) : string('CONTROLPANEL_OK');
	}

	return wantarray ? (0, string('CONTROLPANEL_FAILED')) : string('CONTROLPANEL_FAILED');
}

sub checkPing {
	my ($host, $port, $serviceState) = @_;
	
	return (wantarray ? (0, string('CONTROLPANEL_FAILED')) : string('CONTROLPANEL_FAILED')) unless $host && $serviceState;

	my $p = Net::Ping->new('tcp', 2);

	$p->{port_num} = $port if $port;
	
	my @result = ($p->ping($host) ? 1 : 0);
	push @result, string($p->ping($host) ? 'CONTROLPANEL_OK' : 'CONTROLPANEL_FAILED');
	$p->close();

	return wantarray ? @result : $result[1];
}


1;