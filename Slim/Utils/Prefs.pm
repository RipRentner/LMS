package Slim::Utils::Prefs;

# $Id: Prefs.pm,v 1.17 2003/11/07 18:41:28 dean Exp $

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

use File::Spec::Functions qw(:ALL);
use FindBin qw($Bin);

use Slim::Utils::Misc;
use Slim::Hardware::IR;
use Slim::Utils::Strings qw(string);

my %prefs;
my $prefsPath;
my $prefsFile;
my $canWrite;

sub defaultMP3Dir {
	my $path;
	if (($^O eq 'darwin')) {
		$path = ($ENV{'HOME'} . '/Music');
	} elsif (Slim::Utils::OSDetect::OS() eq 'win') {
		if (!eval "use Win32::Registry;") {
			my $folder;
			if ($::HKEY_CURRENT_USER->Open("Software\\Microsoft\\Windows"
								   ."\\CurrentVersion\\Explorer\\Shell Folders", $folder)) {
				my ($type, $value);
				if ($folder->QueryValueEx("My Music", $type, $value)) {
					$path = $value;
				} elsif ($folder->QueryValueEx("Personal", $type, $value)) {
					$path = $value . '\\My Music';
				}
			}
		}		
	}
	
	if ($path && -d $path) {
		return $path;
	} else {	
		return '';
	}
}

# When adding new server and client preference options, put a default value for the option
# into the DEFAULT hash.  For client options put the key => value pair in the client hash
# in the client key of the main hash.
# If the preference ends in a digit or a # then it will be interpreted as an array preference,
# so if this is not what you intend, don't end it with a digit or a #
my %DEFAULT = (
	"httpport"				=> 9000
	,"cliport"				=> 9090
	,"mp3dir"				=> defaultMP3Dir()
	,"playlistdir"			=> ((Slim::Utils::OSDetect::OS() eq 'mac') ? $ENV{'HOME'} . '/Music/Playlists' : ((Slim::Utils::OSDetect::OS() eq 'win') ? $Bin . '/Playlists' : ''))
	,"skin"					=> "Default"
	,"language"				=> "EN"
	,"refreshRate"			=> 30
	,"displaytexttimeout" 	=> 2.0
	,"filesort"				=> 0
	,"screensavertimeout" 	=> 30
	,"screensaverjump" 		=> 1
	,"playtrackalbum" 		=> 1
	,"artistinalbumsearch" 	=> 0
	,"ignoredarticles"		=> "The El La Los Las Le Les"
	,"authorize"			=> 0				# No authorization by default
	,"username"				=> ''
	,"password"				=> ''
	,"filterHosts"			=> 0				# No filtering by default
	,"allowedHosts"			=> join(',', Slim::Utils::Misc::hostaddr())
	,"tcpReadMaximum"		=> 20
	,"tcpWriteMaximum"		=> 20
	,"tcpConnectMaximum"	=> 30
	,"streamWriteMaximum"	=> 30
	,"udpChunkSize"			=> 1400
	,"usetagdatabase"		=> 0				# use 0 for false, 1 for true
	,"templatecache"		=> 1				# use 0 for false, 1 for true
	,"useplaylistcache"		=> 1 				# use 0 for false, 1 for true
	,"useinfocache"			=> 1				# Perhaps should be 0 for unix?
	,'animationLevel'		=> 3
	,'itemsPerPage'			=> 100
	,'longdateFormat'		=> q(%A, %B |%d, %Y)
	,'shortdateFormat'		=> q(%m/%d/%Y)
	,'timeFormat'			=> q(|%I:%M:%S %p)
	,'titleFormatWeb'		=> 1
    ,'ignoreDirRE'          => ''
    ,'checkVersion'			=> 1
    ,'mDNSname'				=> 'Slim Server'
	,'titleFormat'			=> ['TITLE', 'TRACKNUM. TITLE', 'TRACKNUM. ARTIST - TITLE', 'TRACKNUM. TITLE (ARTIST)'
						, 'TRACKNUM. TITLE - ARTIST - ALBUM', 'FILE.EXT', 'TRACKNUM. TITLE from ALBUM by ARTIST'
						, 'TITLE (ARTIST)', 'ARTIST - TITLE']
	,'menuItem'			=> ['NOW_PLAYING', 'BROWSE_BY_GENRE', 'BROWSE_BY_ARTIST', 'BROWSE_BY_ALBUM', 'BROWSE_MUSIC_FOLDER'
						, 'SEARCH', 'SAVED_PLAYLISTS', 'SETTINGS']
	,'disabledplugins'		=> []
	,'persistPlaylists'		=> 1
	,'reshuffleOnRepeat'		=> 0
	,'transcode-ogg'		=> 1
	,'transcode-mov'		=> 1
	,'transcode-wav'		=> 1
	,'transcodeBitrate'		=> 320	# Maximum bitrate for maximum quality.  MPEG-1 layer III bitrates (kbps): 32 40 48 56 64 80 96 112 128 160 192 224 256 320
	,'savehistory'			=> 1
	,'historylength'		=> 1000
	,'composerInArtists'	=> 1 # include composer and band information in the artists list
	,'livelog'				=> 102400 # keep around an in-memory log of 100kbytes, available from the web interfaces
	,'remotestreamtimeout'  => 5 # seconds to try to connect for a remote stream
	,"CLIENTPREFS" => {
			'autobrightness'	=> 1
			,'doublesize'		=> 0
			,'powerOnBrightness'	=> 4
			,'powerOffBrightness'	=> 1
			,'repeat'		=> 2
			,'volume'		=> 100
			,'treble'		=> 50
			,'bass'			=> 50
			,'shuffle'		=> 0
			,'playingDisplayMode'	=> 0
			,'playername'		=> undef
			,'titleFormatCurr'	=> 1
			,'titleFormat'		=> [5, 1, 3, 6]
			,'disabledirsets'	=> []
			,'irmap'		=> Slim::Hardware::IR::defaultMap()
			,'power'		=> 1
			}
	);

# The following hash contains functions that are executed when the pref corresponding to
# the hash key is changed.  Client specific preferences are contained in a hash stored
# under the main hash key 'CLIENTPREFS'.
# The functions expect the parameters $pref and $newvalue for non-client specific functions
# where $pref is the preference which changed and $newvalue is the new value of the preference.
# Client specific functions also expect a $client param containing a reference to the client
# struct.  The param order is $client,$pref,$newvalue.
my %prefChange = (
	'CLIENTPREFS' => {
		'powerOnBrightness' => sub {
			my ($client,$newvalue) = @_;
			if (Slim::Buttons::Common::mode($client) && Slim::Buttons::Common::mode($client) ne 'off') {
				Slim::Hardware::VFD::vfdBrightness($client,$newvalue);
			}
		}
		,'powerOffBrightness' => sub {
			my ($client,$newvalue) = @_;
			if (Slim::Buttons::Common::mode($client) && Slim::Buttons::Common::mode($client) eq 'off') {
				Slim::Hardware::VFD::vfdBrightness($client,$newvalue);
			}
		}
		,'irmap' => sub {
			my ($client,$newvalue) = @_;
			Slim::Hardware::IR::loadMapFile($newvalue);
			if ($newvalue eq Slim::Hardware::IR::defaultMap()) {
				Slim::Buttons::Plugins::addDefaultMaps();
			}
		}
	}
	,'language' => sub {
		my $newvalue = shift;
		foreach my $client (Slim::Player::Client::clients()) {
			$client->htmlstatusvalid(0);
		}
		Slim::Web::Setup::initSetup();
	}
	,'checkVersion' => sub {
		my $newValue = shift;
		if ($newValue) {
			main::checkVersion();
		}
	}
	,'ignoredarticles' => sub {
		Slim::Music::Info::clearCaseArticleCache();
	}
	,'itunes' => sub {
		my $newvalue = shift;
		foreach my $client (Slim::Player::Client::clients()) {
			Slim::Buttons::Home::updateMenu($client);
		}
		if ($newvalue) {
			Slim::Music::iTunes::startScan();
		} else {
			Slim::Music::MusicFolderScan::startScan();
		}
	}
	,'mp3dir' => sub {
		my $newvalue = shift;
		Slim::Music::MusicFolderScan::startScan();
	}
	,'playlistdir' => sub {
		my $newvalue = shift;
		if (defined($newvalue) && $newvalue ne '' && !-d $newvalue) {
			mkdir $newvalue || ($::d_files && msg("Could not create $newvalue\n"));
		}
		foreach my $client (Slim::Player::Client::clients()) {
			Slim::Buttons::Home::updateMenu($client);
		}
	}
	,'skin' => sub {
		my $newvalue = shift;
		# invalidate any old player status
		foreach my $client (Slim::Player::Client::clients()) {
			$client->htmlstatusvalid(0);
		}
	}
	,'usetagdatabase' => sub {
		my $newvalue = shift;
		if ($newvalue) { #was false, now true
			Slim::Music::Info::init();
		} else { #was true, now false
			Slim::Music::Info::stopCache();
		}
	}
	,'useplaylistcache' => sub {
		my $newvalue = shift;
		Slim::Music::Info::clearCache();
		if ($newvalue || get('useinfocache')) {
			Slim::Music::MusicFolderScan::startScan(1);
		}
	}
	,'useinfocache' => sub {
		my $newvalue = shift;
		Slim::Music::Info::clearCache();
		if ($newvalue || get('useplaylistcache')) {
			Slim::Music::MusicFolderScan::startScan(1);
		}
	}
	,'templatecache' => sub {
		my $newvalue = shift;
		#clear cache whether you are turning it on or off.
		Slim::Web::HTTP::clearCaches();
	}
	,'persistPlaylists' => sub {
		my $newvalue = shift;
		if ($newvalue) {
			Slim::Control::Command::setExecuteCallback(\&Slim::Player::Playlist::modifyPlaylistCallback);
			foreach my $client (Slim::Player::Client::clients()) {
				next if Slim::Player::Sync::isSlave($client);
				Slim::Player::Playlist::modifyPlaylistCallback($client,['playlist','load_done']);
			}
		} else {
			Slim::Control::Command::clearExecuteCallback(\&Slim::Player::Playlist::modifyPlaylistCallback);
		}
	}
	,'historylength' => sub {
		my $newvalue = shift;
		Slim::Web::History::adjustHistoryLength();
	}
);

# Some routines to add and remove preference change handlers
sub addPrefChangeHandler {
	my ($pref,$handlerRef,$forClient) = @_;
	if (defined($pref) && ref($handlerRef) eq 'CODE') {
		if ($forClient) {
			$prefChange{'CLIENTPREFS'}{$pref} = $handlerRef;
		} else {
			$prefChange{$pref} = $handlerRef;
		}
	} else {
		warn "Invalid attempt to add a preference change handler.\n" 
			, defined($pref) ? "Invalid code reference supplied.\n" : "No preference supplied.\n";
	}
}

sub removePrefChangeHandler {
	my ($pref,$forClient) = @_;
	if ($forClient) {
		CORE::delete($prefChange{'CLIENTPREFS'}{$pref});
	} else {
		CORE::delete($prefChange{$pref});
	}
}

sub onChange {
	my $key = shift;
	my $value = shift;
	my $ind = shift;
	my $client = shift;
	
	if (defined($client)) {
		if (defined($key) && exists($prefChange{'CLIENTPREFS'}{$key})) {
			&{$prefChange{'CLIENTPREFS'}{$key}}($client,$value, $key, $ind);
		}
	} else {
		if (defined($key) && exists($prefChange{$key})) {
			&{$prefChange{$key}}($value, $key, $ind);
		}
	}
}

# This makes sure all the server preferences defined in %DEFAULT are in the pref file.
# If they aren't there already they are set to the value in %DEFAULT
sub checkServerPrefs {
	foreach my $key (keys %DEFAULT) {
		next if $key eq "CLIENTPREFS";
		if (!defined($prefs{$key})) {
			if (ref($DEFAULT{$key} eq 'ARRAY')) {
				my @temp = @{$DEFAULT{$key}};
				$prefs{$key} = \@temp;
			} else {
				#$prefs{$key} = $DEFAULT{$key};
				set($key,$DEFAULT{$key});
			}
		}
	}
}

# This makes sure all the client preferences defined in %DEFAULT are in the pref file.
# If they aren't there already they are set to the value in %DEFAULT
sub checkClientPrefs {
	my $client = shift;
	foreach my $key (keys %{$DEFAULT{"CLIENTPREFS"}}) {
		my $clientkey = $client->id() . '-' . $key;
		if (!defined($prefs{$clientkey})) {
			if (ref($DEFAULT{"CLIENTPREFS"}{$key}) eq 'ARRAY') {
				my @temp = @{$DEFAULT{"CLIENTPREFS"}{$key}};
				$prefs{$clientkey} = \@temp;
			} else {
				$prefs{$clientkey} = $DEFAULT{"CLIENTPREFS"}{$key};
			}
		}
	}
}

sub push {
	my $arrayPref = shift;
	my $value = shift;
	if (ref($prefs{$arrayPref}) eq 'ARRAY' || !defined($prefs{$arrayPref})) {
		CORE::push @{$prefs{$arrayPref}}, $value;
	} else {
		bt();
		warn "Attempted to push a value onto a scalar pref";
	}
	writePrefs();
}

sub clientPush {
	my $client = shift;
	my $arrayPref = shift;
	my $value = shift;
	Slim::Utils::Prefs::push(($client->id() . '-' . $arrayPref),$value);
}

# getArrayMax($arrayPref)
sub getArrayMax{
	my $arrayPref = shift;
	if (defined($prefs{$arrayPref}) && ref($prefs{$arrayPref}) eq 'ARRAY') {
		my @prefArray = @{$prefs{$arrayPref}};
		my $max = $#prefArray;
		return $max;
	} else {
		return undef;
	}
}
# clientGetArrayMax($client, $arrayPref)
sub clientGetArrayMax {
	my $client = shift;
	my $arrayPref = shift;
	return getArrayMax($client->id() . "-" . $arrayPref);
}

# getArray($arrayPref)
sub getArray {
	return @{$prefs{(shift)}};
}

# clientGetArray($client, $arrayPref)
sub clientGetArray {
	my $client = shift;
	my $arrayPref = shift;
	return getArray($client->id() . "-" . $arrayPref);
}
# get($pref)
sub get 
{ 
	return $prefs{$_[0]} 
};

# getInd($pref,$index)
sub getInd {
	return $prefs{(shift)}[(shift)];
}

# clientGet($client, $pref [,$ind])
sub clientGet {
	my $client = shift;
	my $key = shift;
	my $ind = shift;
	if (defined($ind)) {
		return getInd($client->id() . "-" . $key,$ind);
	} else {
		return get($client->id() . "-" . $key);
	}
}

sub getDefault {
	my $key = shift;
	my $ind = shift;
	if (defined($ind)) {
		return $DEFAULT{$key}[$ind];
	}
	return $DEFAULT{$key};
}

sub clientGetDefault {
	my $key = shift;
	my $ind = shift;
	if (defined($ind)) {
		return $DEFAULT{'CLIENTPREFS'}{$key}[$ind];
	}
	return $DEFAULT{'CLIENTPREFS'}{$key};
}

sub set {
	my $key = shift;
	my $value = shift;
	my $ind = shift;
	if (!defined $key) {
		return;
	}
	if (defined $ind) {
		if (defined($prefs{$key}[$ind]) && defined($value) && $value eq $prefs{$key}[$ind]) {
				return;
		}
		$prefs{$key}[$ind] = $value;
	} elsif ($key =~ /(.+?)(\d+)$/) { 
		#trying to set a member of an array pref directly
		#re-call function the correct way
		return set($1,$value,$2);
	} else {
		if (defined($prefs{$key}) && defined($value) && $value eq $prefs{$key}) {
				return;
		}
		$prefs{$key} = $value;
	}

	onChange($key, $value, $ind);
	#must mark $ind as defined or indexed prefs cause an error in this msg
	$::d_prefs && msg("Setting prefs $key".defined($ind)." equal to " . ((defined $prefs{$key}) ? $prefs{$key} : "undefined") . "\n");
	writePrefs();
}

sub clientSet {
	my $client = shift;
	my $key = shift;
	my $value = shift;
	my $ind = shift;
	
	set($client->id() . "-" . $key, $value,$ind);
	onChange($key, $value, $ind, $client);
}

sub delete {
	my $key = shift;
	my $ind = shift;
	if (!defined $prefs{$key}) {
		return;
	}
	if (defined($ind)) {
		splice(@{$prefs{$key}},$ind,1);
	} elsif ($key =~ /(.+?)(\d+)$/) { 
		#trying to delete a member of an array pref directly
		#re-call function the correct way
		Slim::Utils::Prefs::delete($1,$2);
	} elsif (ref($prefs{$key}) eq 'ARRAY') {
		#clear an array pref
		$prefs{$key} = [];
	} else {
		CORE::delete $prefs{$key};
	}
	writePrefs();
}

sub clientDelete {
	my $client = shift;
	my $key = shift;
	my $ind = shift;
	
	Slim::Utils::Prefs::delete($client->id() . "-" . $key,$ind);
}

sub isDefined {
	my $key = shift;
	my $ind = shift;
	if (defined($ind)) {
		return defined $prefs{$key}[$ind];
	}
	return defined $prefs{$key};
}

sub clientIsDefined {
	my $client = shift;
	my $key = shift;
	my $ind = shift;
	
	return isDefined($client->id() . "-" . $key,$ind);
}

sub writePrefs {
	if ($canWrite) {
		my $writeFile = prefsFile();
		
		$::d_prefs && msg("Writing out prefs in $writeFile\n");
		
		if (open(NUPREFS, ">$writeFile")) {
			foreach my $k (sort keys (%prefs)) {
				if (defined $prefs{$k}) {
					if (ref($prefs{$k}) eq 'ARRAY') {
						print NUPREFS ($k . '# = ' . getArrayMax($k) . "\n");
						my $i;
						foreach my $val (@{$prefs{$k}}) {
							print NUPREFS ($k . $i++ . " = " . $val . "\n");
						}
					} else {
						print NUPREFS ($k . " = " . $prefs{$k} . "\n");
					}
				}
			}
			close NUPREFS;
		} else {
			msg("Couldn't write preferences file out $writeFile\n");
		}
	}
}


sub preferencesPath {

	if (defined($prefsPath)) {
		return $prefsPath;
	}

	if (Slim::Utils::OSDetect::OS() eq 'mac') {
		$prefsPath = catdir($ENV{'HOME'}, 'Library', 'SlimDevices');
	} elsif (Slim::Utils::OSDetect::OS() eq 'win')  {
		$prefsPath = $Bin;
	} else {
	 	$prefsPath = $ENV{'HOME'};
	}
	
	$::d_prefs && msg("The default prefs directory is $prefsPath\n");

	return  $prefsPath;
}

sub prefsFile {
	my $setFile = shift;
	
	if (defined $setFile) { $prefsFile = $setFile; }
	
	if (defined($prefsFile)) {
		return $prefsFile;
	}

	my $pref_path = preferencesPath();

	if (Slim::Utils::OSDetect::OS() eq 'win')  {	
		$prefsFile = catdir($pref_path, 'slimserver.pref');
	} elsif (Slim::Utils::OSDetect::OS() eq 'mac') {
		$prefsFile = catdir($pref_path, 'slimserver.pref');
	} else {
		if (-r '/etc/slimserver.conf') {
			$prefsFile = '/etc/slimserver.conf';
		} else {
			$prefsFile = catdir($pref_path, '.slimserver.pref');
		}
	}
	
	$::d_prefs && msg("The default prefs file location is $prefsFile\n");
	
	return $prefsFile;
}

#
# Figures out where the preferences file should be on our platform, and loads it.
#
sub load {
	my $setFile = shift;
	my $nosetup = shift;

	my $readFile = prefsFile($setFile);
	
	# if we can't open up the new one, try the old ones
	if (!-r $readFile) {
		$readFile = '/etc/slimp3.pref';
	}
	
	if (!-r $readFile) {
		$readFile = catdir(preferencesPath(), 'SLIMP3.PRF');
	}
	
	if (!-r $readFile) {
		if (exists($ENV{'windir'})) {
			$readFile = catdir($ENV{'windir'}, 'SLIMP3.PRF');
		}
	}
		
	if (!-r $readFile) {
		$readFile = catdir(preferencesPath(), '.slimp3.pref');
	}
	
	if (!-r $readFile) {
		$readFile = catdir($ENV{'HOME'}, '.slimp3.pref');
	}
	
	# if we found some file to read, then let's read it!
	if (-r $readFile) {
		$::d_prefs && msg("reading in prefs file $readFile\n");
		open(NUPREFS, $readFile);
		while (<NUPREFS>) {
			chomp; 			# no newline
			s/^\s+//;		# no leading white
			s/\s+$//;		# no trailing white
			next unless length;	#anything left?
			my ($var, $value) = split(/\s*=\s*/, $_, 2);
			if ($var =~ /(.+?)(\d+|#)$/) {
				#part of array
				unless ($2 eq '#') {
					$prefs{$1}[$2] = $value;
				}
			} else {
				$prefs{$var} = $value;
			}
		}
		close(NUPREFS);	
	}
	
	# see if we can write out the real prefs file
	$canWrite = (-e prefsFile() && -w prefsFile()) || (-w preferencesPath());
	
	# write it out no matter what.
	writePrefs();
	
	if (!$canWrite && !$nosetup) {
		msg("Cannot write to preferences file $prefsFile, any changes made will not be preserved for the next startup of the server\n");
	}
}

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
