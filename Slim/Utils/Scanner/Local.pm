package Slim::Utils::Scanner::Local;

# $Id$
#
# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, version 2.

use strict;

use File::Basename qw(basename dirname);
use FileHandle;
use Path::Class ();
use Scalar::Util qw(blessed);

use Slim::Utils::Misc ();
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Scheduler;

use constant PENDING_DELETE  => 0x01;
use constant PENDING_NEW     => 0x02;
use constant PENDING_CHANGED => 0x04;

my $log = logger('scan.scanner');

my $findclass;
if ( main::HAS_AIO ) {
	$findclass = 'Slim::Utils::Scanner::Local::AIO';
}
else {
	$findclass = 'Slim::Utils::Scanner::Local::Async';
}
eval "use $findclass";
die $@ if $@;

my %pending = ();

sub find {
	my ( $class, $path, $args, $cb ) = @_;
	
	# Return early if we were passed a file
	lstat $path;
	if ( -f _ ) {
		my $types = Slim::Music::Info::validTypeExtensions( $args->{types} || 'audio' );
		
		if ( Slim::Utils::Misc::fileFilter( dirname($path), basename($path), $types, 1 ) ) {
			$cb->( [ [ $path, (stat _)[9], (stat _)[7] ] ] ); # file / mtime / size
		}
		else {
			$cb->( [] );
		}
		
		return;
	}
	
	$findclass->find( $path, $args, $cb );
}

sub rescan {
	my ( $class, $paths, $args ) = @_;
	
	if ( ref $paths ne 'ARRAY' ) {
		$paths = [ $paths ];
	}
	
	my $next = shift @{$paths};
	
	# Strip trailing slashes
	$next =~ s{/$}{};
	
	main::DEBUGLOG && $log->is_debug && $log->debug("Rescanning $next");
	
	$pending{$next} = 0;
	
	if ( !main::SCANNER ) {
		Slim::Music::Import->setIsScanning(1);
	}
	
	# Get list of files within this path
	Slim::Utils::Scanner::Local->find( $next, $args, sub {
		my $count  = shift;
		my $others = shift || []; # other dirs we need to scan (shortcuts/aliases)
		
		my $basedir = Slim::Utils::Misc::fileURLFromPath($next);
		
		my $validRE = Slim::Music::Info::validTypeExtensions( $args->{types} || 'audio' );
		
		my $dbh = Slim::Schema->storage->dbh;
		
		# Generate 3 lists of files:
		
		# 1. Files that no longer exist on disk
		my $inDBOnlySQL = qq{
			SELECT DISTINCT tracks.url
			FROM            tracks
			LEFT JOIN       scanned_files USING (url)
			WHERE           scanned_files.url IS NULL
			AND             tracks.url LIKE '$basedir%'
		};
		
		# 2. Files that are new and not in the database.
		my $onDiskOnlySQL = qq{
			SELECT DISTINCT scanned_files.url
			FROM            scanned_files
			LEFT JOIN       tracks USING (url)
			WHERE           tracks.url IS NULL
			AND             scanned_files.url LIKE '$basedir%'
			ORDER BY        scanned_files.url
		};
		
		# 3. Files that have changed mtime or size.
		my $changedOnlySQL = qq{
			SELECT a.url, a.timestamp, a.filesize FROM (
				SELECT url, timestamp, filesize FROM scanned_files
				WHERE  url IN (
				  SELECT scanned_files.url
				  FROM scanned_files INNER JOIN tracks
				  USING (url)
				)
			) a
			LEFT JOIN tracks USING (url, timestamp, filesize)
			WHERE tracks.url IS NULL
			AND a.url LIKE '$basedir%'
			ORDER BY a.url
		};
		
		my ($inDBOnlyCount) = $dbh->selectrow_array( qq{
			SELECT COUNT(*) FROM ( $inDBOnlySQL ) AS t1
		} );
    	
		my ($onDiskOnlyCount) = $dbh->selectrow_array( qq{
			SELECT COUNT(*) FROM ( $onDiskOnlySQL ) AS t1
		} );
		
		my ($changedOnlyCount) = $dbh->selectrow_array( qq{
			SELECT COUNT(*) FROM ( $changedOnlySQL ) AS t1
		} );
		
		$log->error( "Removing deleted files ($inDBOnlyCount)" ) unless main::SCANNER && $main::progress;
		
		if ( $inDBOnlyCount ) {
			my $inDBOnly = $dbh->prepare_cached($inDBOnlySQL);
			$inDBOnly->execute;
			
			my $deleted;
			$inDBOnly->bind_col(1, \$deleted);

			$pending{$next} |= PENDING_DELETE;
			
			my $progress;
			if ( $args->{progress} ) {
				$progress = Slim::Utils::Progress->new( {
					type  => 'importer',
					name  => $args->{scanName} . '_deleted',
					bar	  => 1,
					every => ($args->{scanName} && $args->{scanName} eq 'playlist'), # record all playists in the db
					total => $inDBOnlyCount,
				} );
			}
			
			my $handle_deleted = sub {
				if ( $inDBOnly->fetch ) {
					$progress && $progress->update($deleted);
					
					# XXX: ignore audio files if in playlist scan and vice-versa
					# Should be handled better by searching based on content_type
					if ( $deleted =~ $validRE ) {
						deleted($deleted);
					}
					
					return 1;
				}
				else {
					markDone( $next => PENDING_DELETE ) unless $args->{no_async};
				
					$progress && $progress->final;
					
					return 0;
				}
			};
			
			if ( $args->{no_async} ) {
				while ( $handle_deleted->() ) {}
			}
			else {
				Slim::Utils::Scheduler::add_task( $handle_deleted );
			}
		}
		
		$log->error( "Scanning new files ($onDiskOnlyCount)" ) unless main::SCANNER && $main::progress;
		
		if ( $onDiskOnlyCount ) {
			my $onDiskOnly = $dbh->prepare_cached($onDiskOnlySQL);
			$onDiskOnly->execute;
			
			my $new;
			$onDiskOnly->bind_col(1, \$new);
			
			$pending{$next} |= PENDING_NEW;
			
			my $progress;
			if ( $args->{progress} ) {
				$progress = Slim::Utils::Progress->new( {
					type  => 'importer',
					name  => $args->{scanName} . '_new',
					bar   => 1,
					every => ($args->{scanName} && $args->{scanName} eq 'playlist'), # record all playists in the db
					total => $onDiskOnlyCount,
				} );
			}
			
			my $handle_new = sub {
				if ( $onDiskOnly->fetch ) {
					$progress && $progress->update($new);
				
					# XXX: ignore audio files if in playlist scan and vice-versa
					# Should be handled better by searching based on content_type
					if ( $new =~ $validRE ) {
						new($new);
					}
					
					return 1;
				}
				else {
					markDone( $next => PENDING_NEW ) unless $args->{no_async};
				
					$progress && $progress->final;
					
					return 0;
				}
			};
			
			if ( $args->{no_async} ) {
				while ( $handle_new->() ) {}
			}
			else {
				Slim::Utils::Scheduler::add_task( $handle_new );
			}
		}
		
		$log->error( "Rescanning changed files ($changedOnlyCount)" ) unless main::SCANNER && $main::progress;
		
		if ( $changedOnlyCount ) {
			my $changedOnly = $dbh->prepare_cached($changedOnlySQL);
			$changedOnly->execute;
			
			my $changed;
			$changedOnly->bind_col(1, \$changed);
						
			$pending{$next} |= PENDING_CHANGED;
			
			my $progress;
			if ( $args->{progress} ) {
				$progress = Slim::Utils::Progress->new( {
					type  => 'importer',
					name  => $args->{scanName} . '_changed',
					bar   => 1,
					every => ($args->{scanName} && $args->{scanName} eq 'playlist'), # record all playists in the db
					total => $changedOnlyCount,
				} );
			}
			
			my $handle_changed = sub {
				if ( $changedOnly->fetch ) {
					$progress && $progress->update($changed);
				
					# XXX: ignore audio files if in playlist scan and vice-versa
					# Should be handled better by searching based on content_type
					if ( $changed =~ $validRE ) {
						changed($changed);
					}
					
					return 1;
				}
				else {
					markDone( $next => PENDING_CHANGED ) unless $args->{no_async};
				
					$progress && $progress->final;
					
					return 0;
				}	
			};
			
			if ( $args->{no_async} ) {
				while ( $handle_changed->() ) {}
			}
			else {
				Slim::Utils::Scheduler::add_task( $handle_changed );
			}
		}
		
		# Scan other directories found via shortcuts or aliases
		if ( scalar @{$others} ) {
			if ( $args->{no_async} ) {
				$class->rescan( $others, $args );
			}
			else {
				Slim::Utils::Timers::setTimer( $class, AnyEvent->now, \&rescan, $others, $args );
			}
		}
		
		# If nothing changed, send a rescan done event
		elsif ( !$inDBOnlyCount && !$onDiskOnlyCount && !$changedOnlyCount ) {
			if ( !main::SCANNER ) {
				Slim::Music::Import->setIsScanning(0);
				Slim::Control::Request::notifyFromArray( undef, [ 'rescan', 'done' ] );
			}
		}
	} );
	
	# Continue scanning if we had more paths
	if ( @{$paths} ) {
		if ( $args->{no_async} ) {
			$class->rescan( $paths, $args );
		}
		else {
			Slim::Utils::Timers::setTimer( $class, AnyEvent->now, \&rescan, $paths, $args );
		}
	}
}

sub deleted {
	my $url = shift;
	
	my $file = Slim::Utils::Misc::pathFromFileURL($url);   
	$log->error("Handling deleted track $file") unless main::SCANNER && $main::progress;

	my $track = Slim::Schema->rs('Track')->search( url => $url )->single;
		
	if ( $track ) {
		my $work = sub {
			my $album    = $track->album;
			my @contribs = $track->contributors->all;
			my $year     = $track->year;
		
			# delete() will cascade to:
			#   contributor_track
			#   genre_track
			#   comments
			$track->delete;

			# Tell Album to rescan, by looking for remaining tracks in album.  If none, remove album.
			$album->rescan if $album;
			
			# Tell Contributors to rescan, if no other tracks left, remove contributor.
			for my $contrib ( @contribs ) {
				$contrib->rescan;
			}
			
			# Tell Year to rescan
			Slim::Schema->rs('Year')->find($year)->rescan if $year;
			
			# XXX Remove cached artwork for this track?
		};
		
		if ( Slim::Schema->storage->dbh->{AutoCommit} ) {
			Slim::Schema->txn_do($work);
		}
		else {
			$work->();
		}
	}
}

sub new {
	my $url = shift;
	
	my $work;
	
	my $file = Slim::Utils::Misc::pathFromFileURL($url);
		
	if ( Slim::Music::Info::isSong($url) ) {
		$log->error("Handling new track $file") unless main::SCANNER && $main::progress;
		
		$work = sub {
			# Scan tags & create track row and other related rows.
			my $track = Slim::Schema->updateOrCreate( {
				url        => $url,
				readTags   => 1,
				new        => 1,
				checkMTime => 0,
				commit     => 0,
			} );
			
			if ( !defined $track ) {
				$log->error( "ERROR SCANNING $file: " . Slim::Schema->lastError );
				return;
			}
			
			# Link album cover to track cover
			my $album = $track->album;
			
			if ( $album && $track->cover && $track->cover == 1 ) {
				if ( !$album->artwork ) {
					$album->artwork( $track->id );
					$album->update;
				}
			}
			
			if ( !main::SCANNER ) {
				# Merge VA (for this album only)
				# Does not merge if the album was previously merged into a compilation
				if ( $album && !$album->compilation ) {
					Slim::Schema->mergeSingleVAAlbum($album);
				}
			}
		};
	}
	elsif ( 
		Slim::Music::Info::isCUE($url)
		|| 
		( Slim::Music::Info::isPlaylist($url) && Slim::Utils::Misc::inPlaylistFolder($url) )
	) {
		# Only read playlist files if we're in the playlist dir. Read cue sheets from anywhere.
		$log->error("Handling new playlist $file") unless main::SCANNER && $main::progress;
		
		$work = sub {		
			my $playlist = Slim::Schema->updateOrCreate( {
				url        => $url,
				readTags   => 1,
				new        => 1,
				playlist   => 1,
				checkMTime => 0,
				commit     => 0,
				attributes => {
					MUSICMAGIC_MIXABLE => 1,
				},
			} );
		
			if ( !defined $playlist ) {
				$log->error( "ERROR SCANNING $file: " . Slim::Schema->lastError );
				return;
			}

			scanPlaylistFileHandle( $playlist, FileHandle->new($file) );
		};
	}
	
	if ( $work ) {
		if ( Slim::Schema->storage->dbh->{AutoCommit} ) {
			Slim::Schema->txn_do($work);
		}
		else {
			$work->();
		}
	}
}

sub changed {
	my $url = shift;
	
	my $isDebug = $log->is_debug;
	
	my $file = Slim::Utils::Misc::pathFromFileURL($url);
	
	$log->error("Handling changed track $file") unless main::SCANNER && $main::progress;
	
	if ( Slim::Music::Info::isSong($url) ) {
		# Fetch the original track record
		my $origTrack = Slim::Schema->objectForUrl( {
			url        => $url,
			readTags   => 0,
			checkMTime => 0,
		} );
		
		my $orig = {
			year   => $origTrack->year,
			genres => [ sort map { $_->id } $origTrack->genres ],
		};
		
		my $work = sub {	
			# Scan tags & update track row.
			my $track = Slim::Schema->updateOrCreate( {
				url        => $url,
				readTags   => 1,
				checkMTime => 0, # not needed as we already know it's changed
				commit     => 0,
			} );
			
			if ( !defined $track ) {
				$log->error( "ERROR SCANNING $file: " . Slim::Schema->lastError );
				return;
			}
			
			my $album = $track->album;
			
			# XXX
			# Album gain is not changed if a value already exists (bug 8034)
			#   Check all other tracks and only update if match?
			#   Or, update on any change found.
			#   See Slim::Schema line 2695
			# Check for updated artwork.
			# Rescan comments
			
			# Rescan genre, to check for no longer used genres
			my $origGenres = join( ',', @{ $orig->{genres} } );
			my $newGenres  = join( ',', sort map { $_->id } $track->genres );
			
			if ( $origGenres ne $newGenres ) {
				main::DEBUGLOG && $isDebug && $log->debug( "Rescanning changed genre(s) $origGenres -> $newGenres" );
				
				Slim::Schema::Genre->rescan( @{ $orig->{genres} } );
			}
			
			# Bug 8034, Rescan years if year value changed, to remove the old year
			if ( $orig->{year} != $track->year ) {
				main::DEBUGLOG && $isDebug && $log->debug( "Rescanning changed year " . $orig->{year} . " -> " . $track->year );
				
				Slim::Schema->rs('Year')->find( $orig->{year} )->rescan;
			}
		
			if ( !main::SCANNER ) {
				# Merge VA (for this album only)
				# Does not merge if the album was previously merged into a compilation
				if ( $album && !$album->compilation ) {
					Slim::Schema->mergeSingleVAAlbum($album);
				}
			}
		};
		
		if ( Slim::Schema->storage->dbh->{AutoCommit} ) {
			Slim::Schema->txn_do($work);
		}
		else {
			$work->();
		}
	}
	
	# XXX changed playlist
}

# Check if we're done with all our rescan tasks
sub markDone {
	my ( $path, $type ) = @_;
	
	main::DEBUGLOG && $log->is_debug && $log->debug("Finished scan type $type for $path");
	
	$pending{$path} &= ~$type;
	
	# Check all pending tasks, make sure all are done before notifying
	for my $task ( keys %pending ) {
		if ( $pending{$task} > 0 ) {
			return;
		}
	}
	
	main::DEBUGLOG && $log->is_debug && $log->debug('All rescan tasks finished');
	
	# Done with all tasks
	if ( !main::SCANNER ) {
		Slim::Music::Import->setIsScanning(0);		
		Slim::Control::Request::notifyFromArray( undef, [ 'rescan', 'done' ] );
	}
	
	%pending = ();
}

=head2 scanPlaylistFileHandle( $playlist, $playlistFH )

Scan a playlist filehandle using L<Slim::Formats::Playlists>.

=cut

sub scanPlaylistFileHandle {
	my $playlist   = shift;
	my $playlistFH = shift || return;
	
	my $url        = $playlist->url;
	my $parentDir  = undef;

	if (Slim::Music::Info::isFileURL($url)) {

		#XXX This was removed before in 3427, but it really works best this way
		#XXX There is another method that comes close if this shouldn't be used.
		$parentDir = Slim::Utils::Misc::fileURLFromPath( Path::Class::file($playlist->path)->parent );

		main::DEBUGLOG && $log->is_debug && $log->debug("Will scan $url, base: $parentDir");
	}

	my @playlistTracks = Slim::Formats::Playlists->parseList(
		$url,
		$playlistFH, 
		$parentDir, 
		$playlist->content_type,
	);

	# Be sure to remove the reference to this handle.
	if (ref($playlistFH) eq 'IO::String') {
		untie $playlistFH;
	}

	undef $playlistFH;

	if (scalar @playlistTracks) {
		$playlist->setTracks(\@playlistTracks);
	}

	# Create a playlist container
	if (!$playlist->title) {

		my $title = Slim::Utils::Misc::unescape(basename($url));
		   $title =~ s/\.\w{3}$//;

		$playlist->title($title);
		$playlist->titlesort( Slim::Utils::Text::ignoreCaseArticles( $title ) );
	}

	# With the special url if the playlist is in the
	# designated playlist folder. Otherwise, Dean wants
	# people to still be able to browse into playlists
	# from the Music Folder, but for those items not to
	# show up under Browse Playlists.
	#
	# Don't include the Shoutcast playlists or cuesheets
	# in our Browse Playlist view either.
	my $ct = Slim::Schema->contentType($playlist);

	if (Slim::Music::Info::isFileURL($url) && Slim::Utils::Misc::inPlaylistFolder($url)) {
		main::DEBUGLOG && $log->is_debug && $log->debug( "Playlist item $url changed from $ct to ssp content-type" );
		$ct = 'ssp';
	}

	$playlist->content_type($ct);
	$playlist->update;
	
	# Copy playlist title to all items if they are remote URLs and do not already have a title
	# XXX: still needed?
	for my $track ( @playlistTracks ) {
		if ( blessed($track) && $track->remote ) {
			my $curTitle = $track->title;
			if ( !$curTitle || Slim::Music::Info::isURL($curTitle) ) {
				$track->title( $playlist->title );
				$track->update;
				
				if ( main::DEBUGLOG && $log->is_debug ) {
					$log->debug( 'Playlist item ' . $track->url . ' given title ' . $track->title );
				}
			}
		}
	}
	
	if ( main::DEBUGLOG && $log->is_debug ) {

		$log->debug(sprintf("Found %d items in playlist: ", scalar @playlistTracks));

		for my $track (@playlistTracks) {

			$log->debug(sprintf("  %s", blessed($track) ? $track->url : ''));
		}
	}

	return wantarray ? @playlistTracks : \@playlistTracks;
}

1;
	
