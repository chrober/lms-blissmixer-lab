package Plugins::BlissMixerLab::EssentiaShadowProbe;

use strict;
use warnings;

use DBI;
use DBD::SQLite::Constants qw(SQLITE_OPEN_READONLY);
use File::Spec;
use File::Temp ();
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);

use Plugins::BlissMixerLab::EssentiaExactIdentity ();

# Explicit experimental runner. Never called from the live Lab mixer.
# Both source databases are opened with SQLite's actual READONLY flag.
# SQLite online backups give independently frozen, WAL-aware copies; they
# are not a globally atomic snapshot of two separate source databases.
sub _frozen_copy {
    my ($source, $target, $limit) = @_;
    die 'untrusted source database'
        unless defined $source && File::Spec->file_name_is_absolute($source)
            && -f $source && -r $source && !-l $source;
    die 'untrusted snapshot destination'
        unless defined $target && File::Spec->file_name_is_absolute($target)
            && !-e $target;
    die 'database exceeds experimental copy limit'
        if (-s $source) > $limit;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$source", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
        sqlite_unicode => 1, sqlite_open_flags => SQLITE_OPEN_READONLY,
    }) or die 'read-only database unavailable';
    $dbh->do('PRAGMA query_only = ON');
    my $result = eval { $dbh->sqlite_backup_to_file($target); 1 };
    $dbh->disconnect;
    die 'SQLite online backup failed' unless $result && -f $target;
    die 'snapshot exceeds experimental copy limit'
        if (-s $target) > $limit;
    chmod 0400, $target or die 'cannot restrict frozen feature snapshot';
    my $frozen = DBI->connect("dbi:SQLite:dbname=$target", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
        sqlite_unicode => 1, sqlite_open_flags => SQLITE_OPEN_READONLY,
    }) or die 'read-only snapshot unavailable';
    $frozen->do('PRAGMA query_only = ON');
    return $frozen;
}

# Build a complete SPI v2 transcript on immutable snapshots, and send it only
# to an explicitly selected, locally installed native provider executable.
sub run_shadow {
    my (%args) = @_;
    return { status => 'neutral_fallback', reason => 'NOT_ENABLED' }
        unless $args{shadow_opt_in};
    my $phase = 'validation';
    my $status = eval {
        die 'trusted native executable required'
            unless defined($args{provider_binary})
                && File::Spec->file_name_is_absolute($args{provider_binary})
                && -f $args{provider_binary} && -x $args{provider_binary}
                && !-l $args{provider_binary};
        die 'model must be explicit'
            unless ($args{model_id} || '') =~ /\A(?:genre|moodtheme)\z/
                && ($args{metric} || '') =~ /\A(?:affine_cosine_v1|affine_centered_cosine_v1)\z/
                && ($args{expected_model_key} || '') =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
        my $job_id = $args{job_id};
        die 'valid job ID required'
            unless defined($job_id) && $job_id =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
        my $tracks = $args{candidates};
        my $seeds = $args{anchors};
        die 'one anchor, complete bounded pool required'
            unless ref($seeds) eq 'ARRAY' && @$seeds == 1
                && ref($tracks) eq 'ARRAY' && @$tracks >= 2 && @$tracks <= 50;
        my $limit = 256 * 1024 * 1024; # Explicit resource safety bound.
        my $temp = File::Temp->newdir('essentia-shadow-XXXXXXXX', CLEANUP => 1);
        my $dir = "$temp";
        my $bliss_copy = File::Spec->catfile($dir, 'bliss-frozen.sqlite');
        my $feature_copy = File::Spec->catfile($dir, 'features-frozen.sqlite');
        $phase = 'source_backup';
        my $bliss = _frozen_copy($args{bliss_db}, $bliss_copy, $limit);
        my $features = _frozen_copy($args{feature_db}, $feature_copy, $limit);
        die 'wrong sidecar schema'
            unless $features->selectrow_array('PRAGMA user_version') == 3;
        $phase = 'identity';
        my $verify = Plugins::BlissMixerLab::EssentiaExactIdentity::verifier_from_db_handles(
            $bliss, $features
        );
        my $artifact = Plugins::BlissMixerLab::EssentiaExactIdentity::write_artifact(
            anchors => $seeds, candidates => $tracks, media_dirs => $args{media_dirs},
            windows => $args{windows}, job_id => $job_id, directory => $dir,
            verify_key => $verify,
        );
        # All track keys come from the verified artifact; never from urlmd5
        # or the user-provided model/metadata fields.
        my $bytes = do {
            open my $afh, '<:raw', $artifact->{path} or die 'artifact unavailable';
            local $/;
            my $data = <$afh>;
            close $afh;
            $data;
        };
        my $mapping = JSON::PP->new->utf8->decode($bytes);
        my @items = @{$mapping->{tracks}};
        die 'identity cohort not complete' unless @items == 1 + @$tracks;
        my $anchor = $items[0];
        my @candidates = map {
            { candidate_id => $_->{track_id}, database_file => $_->{track_file} }
        } @items[1 .. $#items];
        $bliss->disconnect;
        $features->disconnect;
        my @requests = (
            { type => 'describe', spi_version => 2 },
            {
                type => 'prepare', spi_version => 2, job_id => $job_id,
                options => {
                    model_id => $args{model_id},
                    metric => $args{metric},
                    expected_model_key => $args{expected_model_key},
                    experimental_preview_opt_in => $args{experimental_preview_opt_in}
                        ? JSON::PP::true : JSON::PP::false,
                },
                artifacts => [$artifact],
                resources => [{
                    kind => 'essentia-feature-sqlite-v3',
                    path => $feature_copy, access => 'read_only',
                }],
                anchors => [{
                    anchor_id => $anchor->{track_id},
                    candidate_id => $anchor->{track_id},
                    database_file => $anchor->{track_file},
                }],
            },
            {
                type => 'score', spi_version => 2,
                request_id => 'essentia-shadow-query',
                context => {
                    scope => 'global', context_track_ids => [$anchor->{track_id}],
                },
                candidates => \@candidates,
            },
            { type => 'close', spi_version => 2 },
        );
        $phase = 'native_process';
        my $responses = _native_transcript($args{provider_binary}, \@requests);
        die 'incorrect SPI response count' unless @$responses == 4;
        my ($manifest, $prepared, $scored, $closed) = @$responses;
        $phase = 'manifest';
        die 'unsupported native manifest'
            unless ($manifest->{type} || '') eq 'manifest'
                && ($manifest->{provider_id} || '') eq 'essentia-guidance'
                && ($manifest->{protocol} || '') eq 'bliss-guidance-jsonl-v2'
                && ($manifest->{spi_version} || 0) == 2
                && ref($manifest->{channels}) eq 'ARRAY'
                && @{$manifest->{channels}} == 1
                && ref($manifest->{channels}[0]{supported_host_policies}) eq 'ARRAY'
                && @{$manifest->{channels}[0]{supported_host_policies}} == 0;
        $phase = 'prepared';
        die 'provider failed prepare' unless ($prepared->{type} || '') eq 'prepared'
            && ($prepared->{provider_id} || '') eq 'essentia-guidance';
        $phase = 'scores';
        die 'unsafe or malformed score response'
            unless ($scored->{type} || '') eq 'scores'
                && ($scored->{provider_id} || '') eq 'essentia-guidance'
                && ($scored->{request_id} || '') eq 'essentia-shadow-query'
                && ref($scored->{signals}) eq 'ARRAY' && @{$scored->{signals}} == 0
                && ref($scored->{diagnostics}) eq 'HASH';
        $phase = 'closed';
        die 'provider failed close' unless ($closed->{type} || '') eq 'closed'
            && ($closed->{provider_id} || '') eq 'essentia-guidance';
        my $state = $scored->{diagnostics}{state} || '';
        $phase = 'outcome';
        die 'unknown shadow outcome'
            unless $state eq 'shadow_evaluated_no_active_signals'
                || $state eq 'neutral_fallback';
        {
            status => $state, candidate_count => scalar(@$tracks),
            # Only one of these neutral public categories is exposed.
            reason => $state eq 'neutral_fallback' ? 'FEATURE_OR_MODEL_UNAVAILABLE' : undef,
        };
    };
    # No exception details, paths, SQL or track identifiers escape the probe.
    return $@ || ref($status) ne 'HASH'
        ? { status => 'neutral_fallback', reason => 'SHADOW_PROBE_UNAVAILABLE', phase => $phase }
        : $status;
}

sub _native_transcript {
    my ($program, $requests) = @_;
    my $child;
    my @responses;
    my $ok = eval {
        local $SIG{ALRM} = sub { die 'provider deadline exceeded' };
        alarm 15; # This is a deliberately separate, manual research probe.
        open my $devnull, '>', File::Spec->devnull()
            or die 'stderr sink unavailable';
        my ($in, $out);
        $child = open3($in, $out, $devnull, $program);
        my $json = JSON::PP->new->canonical->utf8;
        for my $request (@$requests) {
            print {$in} $json->encode($request), "\n" or die 'provider write failed';
        }
        close $in or die 'provider stdin close failed';
        my $total = 0;
        while (my $line = <$out>) {
            $total += length($line);
            die 'oversized provider response' if $total > 64 * 1024;
            push @responses, $json->decode($line);
            die 'extra provider response' if @responses > 4;
        }
        close $out;
        waitpid($child, 0);
        die 'native provider exited unsuccessfully' if $? != 0;
        $child = undef;
        alarm 0;
        1;
    };
    if (!$ok) {
        alarm 0;
        if ($child) {
            kill 'TERM', $child;
            waitpid($child, 0);
        }
        die 'provider transcript failed';
    }
    return \@responses;
}

1;
